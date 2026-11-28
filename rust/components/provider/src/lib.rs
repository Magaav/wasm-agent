//! THE PROVIDER MODULE (claude-inside-wa, split A slice 2): /login and /model behind `wa:provider`.
//!
//! WHAT THIS COMPONENT OWNS: the contract's shape and the two verbs a reader reaches for - the accounts this
//! node is signed in to (/login), and the models those accounts can call (/model). They are one component
//! because they are one question: a model id means nothing without the account that reaches it, and a login is
//! finished by choosing a model.
//!
//! WHAT IT DOES NOT OWN, on purpose: a provider. Nothing here names an endpoint, a header, a model id or a
//! credential. Each provider is its own component behind the same interface (`wa:provider/provider-module`),
//! so updating one never recompiles this, and two providers cannot drift into each other.
//!
//! THIS SLICE IS THE FOUNDATION, AND IT SAYS SO RATHER THAN PRETENDING: every entry point answers
//! `unsupported` with the name of the step, because no provider module is installed behind it yet. That is
//! what makes the contract buildable and testable before the first provider exists - and the refusal is a
//! sentence a reader can act on ("no provider module is installed") instead of an empty list that would read
//! as "you are signed in to nothing".
wit_bindgen::generate!({
    path: "wit",
    world: "provider",
    generate_all,
});

use exports::wa::provider::provider_module::{
    Account, CallRequest, Error, Event, Guest as ProviderGuest, LoginStep, Model,
};
use wa::kernel::log::{self, Level};

struct ProviderService;

/// The one refusal this slice gives: named, and saying what to do about it.
fn no_module(step: &str) -> Error {
    Error::Unsupported(format!(
        "no provider module is installed behind this component yet ({step}): a node signs in through a \
         provider module, and none is registered"
    ))
}

impl ProviderGuest for ProviderService {
    async fn list_accounts() -> Result<Vec<Account>, Error> {
        Err(no_module("list-accounts"))
    }

    async fn begin_login(_hint: Option<String>) -> Result<LoginStep, Error> {
        Err(no_module("begin-login"))
    }

    async fn continue_login(_session: String, _input: String) -> Result<LoginStep, Error> {
        Err(no_module("continue-login"))
    }

    async fn sign_out(_account: String) -> Result<(), Error> {
        Err(no_module("sign-out"))
    }

    async fn list_models(_account: String) -> Result<Vec<Model>, Error> {
        Err(no_module("list-models"))
    }

    async fn call_model(_request: CallRequest) -> Result<wit_bindgen::StreamReader<Event>, Error> {
        Err(no_module("call-model"))
    }
}

impl exports::wa::kernel::service::Guest for ProviderService {
    async fn run(_config: String) -> Result<(), String> {
        // The kernel's service entry: a component that exports no work of its own still says what it is when
        // the supervisor starts it, so "it started and did nothing" is never a silent state.
        log::write(
            Level::Info,
            "provider",
            "the contract is installed; no provider module is registered yet",
        );
        Ok(())
    }
}

export!(ProviderService);
