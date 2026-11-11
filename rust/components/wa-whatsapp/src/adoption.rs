//! The cutover import contract, proved natively.
//!
//! `scripts/whatsapp-adopt.mjs export` turns a copy of a Go/whatsmeow device store into the `dev`
//! record this component reads. That record is `wacore::store::Device`, which lives behind the
//! wasm32-only `store` module, but the type itself is a plain dependency and deserializes on the
//! host: this module pins the exporter's output against it without a wasm target, a node or a phone.
//!
//! The fixture is deterministic (`whatsapp-adopt.mjs fixture`) and `scripts/test-whatsapp-adopt.mjs`
//! regenerates it byte for byte, so the exporter, the fixture and this test cannot drift apart.
use wacore::store::Device;

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = include_str!("../tests/fixtures/adopted-dev.json");

    #[test]
    fn an_exported_whatsmeow_device_is_a_wacore_device() {
        let device: Device = serde_json::from_str(FIXTURE).expect("the exporter's record deserializes");
        assert_eq!(
            device.pn.as_ref().map(ToString::to_string).as_deref(),
            Some("5511000000000:9@s.whatsapp.net"),
            "the paired PN with its device id is the one the phone linked"
        );
        assert_eq!(
            device.lid.as_ref().map(ToString::to_string).as_deref(),
            Some("72103978127547:9@lid"),
            "the LID identity travels with the PN"
        );
        assert_eq!(device.registration_id, 123456789);
        assert_eq!(device.signed_pre_key_id, 1);
        assert!(device.account.is_some(), "the phone-signed ADV identity travelled");
        for pair in [&device.noise_key, &device.identity_key, &device.signed_pre_key] {
            let derived = pair.private_key.public_key().expect("a readable private key");
            assert_eq!(
                derived.public_key_bytes(),
                pair.public_key.public_key_bytes(),
                "the public half is the one the private key derives"
            );
        }
        let account = device.account.unwrap();
        assert_eq!(account.details.as_deref().map(<[u8]>::len), Some(32), "details");
        assert_eq!(account.account_signature_key.as_deref().map(<[u8]>::len), Some(32), "account signature key");
        assert_eq!(account.account_signature.as_deref().map(<[u8]>::len), Some(64), "account signature");
        assert_eq!(account.device_signature.as_deref().map(<[u8]>::len), Some(64), "device signature");
    }

    #[test]
    fn a_record_without_the_adv_identity_is_refused_by_the_exporter_not_by_a_connect() {
        // The exporter's `check` refuses an empty account; this pins the same property on the Rust
        // side: a device whose account is absent is readable but cannot claim its identity.
        let mut value: serde_json::Value = serde_json::from_str(FIXTURE).unwrap();
        value["account"] = serde_json::Value::Null;
        let device: Device = serde_json::from_value(value).expect("a record without account still reads");
        assert!(device.account.is_none());
    }
}
