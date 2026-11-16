//! Tweaks: copy .dylib files into the app's Frameworks and add a load command for each to the main binary.
//! Signing afterwards signs them with the app.

use std::path::Path;

use crate::error::{QuayError, Result};

const MH_MAGIC_64: u32 = 0xfeed_facf;
const FAT_MAGIC: u32 = 0xcafe_babe;
const LC_SEGMENT_64: u32 = 0x19;
const LC_LOAD_WEAK_DYLIB: u32 = 0x8000_0018;

/// A copy of `ipa_path` at `out_ipa_path` with the dylibs injected.
#[uniffi::export]
pub fn inject_dylibs(ipa_path: String, dylib_paths: Vec<String>, out_ipa_path: String) -> Result<()> {
    let work = std::env::temp_dir().join(format!("quay-inject-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work)?;
    let result = (|| {
        zip::ZipArchive::new(std::fs::File::open(&ipa_path)?)
            .and_then(|mut z| z.extract(&work))
            .map_err(|_| QuayError::ipa("Не удалось распаковать .ipa"))?;
        let app = std::fs::read_dir(work.join("Payload"))?
            .flatten()
            .map(|e| e.path())
            .find(|p| p.extension().is_some_and(|e| e == "app"))
            .ok_or_else(|| QuayError::ipa("В .ipa нет Payload/*.app"))?;
        let info: plist::Dictionary = plist::from_file(app.join("Info.plist")).map_err(|_| QuayError::ipa("Info.plist не читается"))?;
        let exe = info
            .get("CFBundleExecutable")
            .and_then(|v| v.as_string())
            .ok_or_else(|| QuayError::ipa("Нет CFBundleExecutable"))?;
        let frameworks = app.join("Frameworks");
        std::fs::create_dir_all(&frameworks)?;
        let mut binary = std::fs::read(app.join(exe))?;
        for d in &dylib_paths {
            let name = Path::new(d).file_name().ok_or_else(|| QuayError::ipa("Неверный путь к твику"))?.to_string_lossy().to_string();
            std::fs::copy(d, frameworks.join(&name))?;
            add_load_command(&mut binary, &format!("@executable_path/Frameworks/{name}"))?;
        }
        std::fs::write(app.join(exe), binary)?;
        crate::signing::zip_app(&app, Path::new(&out_ipa_path))
    })();
    let _ = std::fs::remove_dir_all(&work);
    result
}

fn u32le(b: &[u8], at: usize) -> u32 {
    u32::from_le_bytes(b[at..at + 4].try_into().unwrap())
}

fn u32be(b: &[u8], at: usize) -> u32 {
    u32::from_be_bytes(b[at..at + 4].try_into().unwrap())
}

/// Every arm64 slice (thin or fat) gets the command; already present ones are left alone.
pub fn add_load_command(binary: &mut [u8], path: &str) -> Result<()> {
    if binary.len() < 32 {
        return Err(QuayError::ipa("Исполняемый файл приложения повреждён"));
    }
    let slices: Vec<usize> = if u32be(binary, 0) == FAT_MAGIC {
        let n = u32be(binary, 4) as usize;
        (0..n).map(|i| u32be(binary, 8 + i * 20 + 8) as usize).collect()
    } else {
        vec![0]
    };
    for off in slices {
        add_to_slice(&mut binary[off..], path)?;
    }
    Ok(())
}

fn add_to_slice(b: &mut [u8], path: &str) -> Result<()> {
    if u32le(b, 0) != MH_MAGIC_64 {
        return Err(QuayError::ipa("Твики встраиваются только в 64-битные приложения"));
    }
    let ncmds = u32le(b, 16) as usize;
    let sizeofcmds = u32le(b, 20) as usize;
    let cmds_end = 32 + sizeofcmds;
    if path.len() > 900 || cmds_end > b.len() {
        return Err(QuayError::ipa("Исполняемый файл приложения повреждён"));
    }
    if b[32..cmds_end].windows(path.len()).any(|w| w == path.as_bytes()) {
        return Ok(());
    }
    // The first section's file offset: load commands may grow into the padding before it.
    let mut first_data = b.len();
    let mut at = 32;
    for _ in 0..ncmds {
        let (cmd, size) = (u32le(b, at), u32le(b, at + 4) as usize);
        if cmd == LC_SEGMENT_64 {
            let nsects = u32le(b, at + 64) as usize;
            for s in 0..nsects {
                let off = u32le(b, at + 72 + s * 80 + 48) as usize;
                if off > 0 {
                    first_data = first_data.min(off);
                }
            }
        }
        at += size;
    }
    let cmdsize = (24 + path.len() + 1).div_ceil(8) * 8;
    if cmds_end + cmdsize > first_data {
        return Err(QuayError::ipa("В исполняемом файле нет места для твика"));
    }
    let mut cmd = vec![0u8; cmdsize];
    cmd[0..4].copy_from_slice(&LC_LOAD_WEAK_DYLIB.to_le_bytes());
    cmd[4..8].copy_from_slice(&(cmdsize as u32).to_le_bytes());
    cmd[8..12].copy_from_slice(&24u32.to_le_bytes());
    cmd[16..20].copy_from_slice(&0x0001_0000u32.to_le_bytes()); // current version 1.0.0
    cmd[20..24].copy_from_slice(&0x0001_0000u32.to_le_bytes()); // compatibility version 1.0.0
    cmd[24..24 + path.len()].copy_from_slice(path.as_bytes());
    b[cmds_end..cmds_end + cmdsize].copy_from_slice(&cmd);
    b[16..20].copy_from_slice(&((ncmds + 1) as u32).to_le_bytes());
    b[20..24].copy_from_slice(&((sizeofcmds + cmdsize) as u32).to_le_bytes());
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A thin arm64 Mach-O: one LC_SEGMENT_64 with one section whose data starts at 0x400.
    fn fake_macho() -> Vec<u8> {
        let mut b = vec![0u8; 0x800];
        b[0..4].copy_from_slice(&MH_MAGIC_64.to_le_bytes());
        b[16..20].copy_from_slice(&1u32.to_le_bytes());
        b[20..24].copy_from_slice(&(72u32 + 80).to_le_bytes());
        b[32..36].copy_from_slice(&LC_SEGMENT_64.to_le_bytes());
        b[36..40].copy_from_slice(&(72u32 + 80).to_le_bytes());
        b[32 + 64..32 + 68].copy_from_slice(&1u32.to_le_bytes());
        b[32 + 72 + 48..32 + 72 + 52].copy_from_slice(&0x400u32.to_le_bytes());
        b
    }

    #[test]
    fn adds_one_command_once() {
        let mut b = fake_macho();
        add_load_command(&mut b, "@executable_path/Frameworks/T.dylib").unwrap();
        add_load_command(&mut b, "@executable_path/Frameworks/T.dylib").unwrap();
        assert_eq!(u32le(&b, 16), 2);
        let at = 32 + 152;
        assert_eq!(u32le(&b, at), LC_LOAD_WEAK_DYLIB);
        assert_eq!(&b[at + 24..at + 24 + 35], b"@executable_path/Frameworks/T.dylib");
    }

    #[test]
    fn refuses_without_room() {
        let mut b = fake_macho();
        b[32 + 72 + 48..32 + 72 + 52].copy_from_slice(&200u32.to_le_bytes());
        assert!(add_load_command(&mut b, "@executable_path/Frameworks/T.dylib").is_err());
    }
}
