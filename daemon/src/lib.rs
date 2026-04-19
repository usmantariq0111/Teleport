//! Teleport daemon — core modules.
//!
//! The binary entry-point lives in `main.rs`; everything substantive
//! lives here so it can be tested in isolation.

pub mod crypto;
pub mod network;
pub mod path_safe;
pub mod proto;
