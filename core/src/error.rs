/// Every error the Swift side can get. The message is ready to show (Russian).
#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum QuayError {
    #[error("{message}")]
    Network { message: String },
    #[error("{message}")]
    InvalidSource { message: String },
    #[error("{message}")]
    InvalidIpa { message: String },
    #[error("{message}")]
    Device { message: String },
    #[error("{message}")]
    Auth { message: String },
    #[error("{message}")]
    Signing { message: String },
    #[error("{message}")]
    Install { message: String },
    #[error("{message}")]
    Storage { message: String },
    #[error("Отменено")]
    Cancelled,
}

impl QuayError {
    pub fn network(m: impl std::fmt::Display) -> Self {
        Self::Network { message: m.to_string() }
    }
    pub fn source(m: impl std::fmt::Display) -> Self {
        Self::InvalidSource { message: m.to_string() }
    }
    pub fn ipa(m: impl std::fmt::Display) -> Self {
        Self::InvalidIpa { message: m.to_string() }
    }
    pub fn device(m: impl std::fmt::Display) -> Self {
        Self::Device { message: m.to_string() }
    }
    pub fn auth(m: impl std::fmt::Display) -> Self {
        Self::Auth { message: m.to_string() }
    }
    pub fn signing(m: impl std::fmt::Display) -> Self {
        Self::Signing { message: m.to_string() }
    }
    pub fn install(m: impl std::fmt::Display) -> Self {
        Self::Install { message: m.to_string() }
    }
    pub fn storage(m: impl std::fmt::Display) -> Self {
        Self::Storage { message: m.to_string() }
    }
}

impl From<reqwest::Error> for QuayError {
    fn from(e: reqwest::Error) -> Self {
        if e.is_timeout() {
            Self::network("Сервер не ответил вовремя")
        } else if e.is_connect() {
            Self::network("Нет соединения с сервером")
        } else {
            Self::network(format!("Ошибка сети: {e}"))
        }
    }
}

impl From<std::io::Error> for QuayError {
    fn from(e: std::io::Error) -> Self {
        Self::storage(format!("Ошибка файла: {e}"))
    }
}

pub type Result<T> = std::result::Result<T, QuayError>;
