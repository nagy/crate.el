//! A private module with a nested inline module.

pub fn hidden_public() {}

mod inner {
    pub fn deep() {}
}
