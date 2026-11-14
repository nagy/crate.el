//! Harness crate for the crate.el tree tests.
//!
//! Every item below covers one parser rule: module nesting, private
//! items, restricted visibility, inherent and trait impls, enum
//! variants, struct fields, consts, statics, macros and attributes.

pub mod api;
mod hidden;
pub mod money;

pub use api::Request;

/// A public root function.
pub fn root_public() {}

fn root_private() {}

pub(crate) struct Half {
    pub left: u8,
    right: u8,
}

pub const LIMIT: usize = 8;

pub static NAME: &str = "harness";

pub type Alias = Option<u8>;

pub unsafe trait Greet {
    const KIND: u8 = 1;

    fn hello(&self) -> String;

    fn shout(&self) -> String {
        self.hello().to_uppercase()
    }
}

unsafe impl Greet for Half {
    fn hello(&self) -> String {
        "half".into()
    }
}

impl Half {
    pub fn new() -> Self {
        Half { left: 0, right: 0 }
    }

    fn secret(&self) -> u8 {
        self.right
    }

    pub async fn fetch(&self) -> u8 {
        1
    }

    pub const fn fixed() -> u8 {
        2
    }

    pub unsafe fn risky(&self) {}

    pub fn generic<T: Copy>(&self, value: T) -> T {
        value
    }
}

#[deprecated(note = "use Color instead")]
pub enum Color {
    /// The red variant.
    Red,
    Green(u8),
    Blue { deep: bool },
}

impl Color {
    pub fn name(&self) -> &'static str {
        "color"
    }
}

#[macro_export]
macro_rules! make_half {
    () => {
        1
    };
}

#[cfg(test)]
mod tests {
    #[test]
    fn it_works() {
        assert_eq!(2 + 2, 4);
    }
}
