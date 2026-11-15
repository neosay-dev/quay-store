//! isideload's state (anisette provisioning, the signing certificate and its key) in one JSON file
//! inside the app's sandbox (Application Support/quay). iOS encrypts it with the device.

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::Mutex;

use isideload::util::storage::SideloadingStorage;
use rootcause::prelude::*;

pub struct FileStorage {
    path: PathBuf,
    data: Mutex<BTreeMap<String, String>>,
}

impl FileStorage {
    pub fn open(dir: &str) -> Self {
        let path = PathBuf::from(dir).join("isideload-state.json");
        let data = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_default();
        Self { path, data: Mutex::new(data) }
    }

    fn save(&self, data: &BTreeMap<String, String>) -> Result<(), Report> {
        if let Some(dir) = self.path.parent() {
            std::fs::create_dir_all(dir)?;
        }
        let tmp = self.path.with_extension("json.tmp");
        std::fs::write(&tmp, serde_json::to_vec(data)?)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }
}

impl SideloadingStorage for FileStorage {
    fn store(&self, key: &str, value: &str) -> Result<(), Report> {
        let mut data = self.data.lock().map_err(|_| report!("storage lock poisoned"))?;
        if value.is_empty() {
            data.remove(key);
        } else {
            data.insert(key.to_string(), value.to_string());
        }
        self.save(&data)
    }

    fn retrieve(&self, key: &str) -> Result<Option<String>, Report> {
        let data = self.data.lock().map_err(|_| report!("storage lock poisoned"))?;
        Ok(data.get(key).cloned())
    }
}

/// Forget the Apple ID state: anisette identity and the stored certificate (Settings → sign out).
#[uniffi::export]
pub fn reset_signing_state(storage_dir: String) -> crate::error::Result<()> {
    let path = PathBuf::from(storage_dir).join("isideload-state.json");
    if path.exists() {
        std::fs::remove_file(path)?;
    }
    Ok(())
}
