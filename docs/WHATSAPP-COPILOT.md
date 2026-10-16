# WhatsApp

Current backend: persistent linked-device `wa-whatsapp`, not browser/CDP automation.
See [connector setup and limits](WHATSAPP-CONNECTOR.md) and the mandatory
[legacy migration/retirement procedure](WHATSAPP-MIGRATION.md).

Default is OFF and recognition language EN. Configure this operator's account
explicitly as PT. Both incoming and phone/other-device outgoing audio are eligible
after explicit cutover; transcripts are clearly marked, source-linked and posted
in the original chat. Initial history is journal-only; post-activation backlog has
no ten-minute transcript expiry. General AI replies are not newly enabled.

The former copilot job is a retirement tombstone; never enable it as a source keeper.
No Chrome, CDP hook/task repair, UI input or silent browser fallback remains in the
canonical path. Existing scope/approval/effect safeguards and historical ledgers remain.
Cross-device drafts are unsupported, so GENERAL model sends fail closed.

This source is staged; no production installation, legacy settlement, pairing or
real message proof is claimed. Original browser-era instructions/failure/proof evidence:
[historical copilot document](history/whatsapp-browser/WHATSAPP-COPILOT.md).
