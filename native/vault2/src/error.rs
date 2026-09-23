use std::io;

/// Errors of drive vault operations.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("{0}")]
    Io(#[from] io::Error),
    /// Something in the vault is damaged or was changed from outside.
    #[error("the vault is damaged: {0}")]
    Corrupt(String),
    #[error("not found")]
    NotFound,
    #[error("already exists")]
    AlreadyExists,
    #[error("not a folder")]
    NotADirectory,
    #[error("is a folder")]
    IsADirectory,
    #[error("the folder is not empty")]
    DirectoryNotEmpty,
    #[error("invalid name")]
    InvalidName,
    /// The key doesn't belong to this vault.
    #[error("the key doesn't open this vault")]
    WrongKey,
    /// Not possible for this item, like deleting the top folder.
    #[error("not allowed")]
    NotAllowed,
    /// The caller cancelled a long operation.
    #[error("cancelled")]
    Cancelled,
    /// The source contains something a vault can't store.
    #[error("{0}")]
    Unsupported(String),
    /// The vault doesn't match the folder it was compared with.
    #[error("{0}")]
    Mismatch(String),
}

impl Error {
    pub(crate) fn corrupt(what: impl Into<String>) -> Self {
        Self::Corrupt(what.into())
    }

    /// Maps "not found" and "already exists" I/O errors to their own
    /// variants.
    pub(crate) fn from_io(error: io::Error) -> Self {
        match error.kind() {
            io::ErrorKind::NotFound => Self::NotFound,
            io::ErrorKind::AlreadyExists => Self::AlreadyExists,
            _ => Self::Io(error),
        }
    }
}

pub type Result<T> = std::result::Result<T, Error>;
