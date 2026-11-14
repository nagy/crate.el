//! Request handling.

pub mod net;
pub mod parse;

pub struct Request {
    pub url: String,
}

impl Request {
    pub fn send(&self) -> bool {
        true
    }
}
