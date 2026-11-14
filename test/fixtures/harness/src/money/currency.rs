//! Currencies.

pub enum Currency {
    Eur,
    Usd,
}

pub fn rate(currency: Currency) -> f64 {
    match currency {
        Currency::Eur => 1.0,
        Currency::Usd => 1.1,
    }
}
