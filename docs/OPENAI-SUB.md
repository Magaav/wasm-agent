# OpenAI subscription

Select **OpenAI subscription** (`openai-sub`) in the model picker, then
`gpt-6-luna`, `gpt-6-sol`, or `gpt-6-astra`. OpenCode Go remains a separate provider.

This route uses Pi's `openai-codex` ChatGPT subscription login and its Responses
adapter, including locked OAuth refresh. Run `/login` in Pi and choose OpenAI
if not already signed in. No OpenAI API key is required. Credentials stay in
Pi's auth store; wasm-agent never copies them into its configuration or commands.

Node and a current Pi installation are required on the machine running the node.
`WASM_AGENT_PI_PACKAGE` can point at the installed `pi-coding-agent` package directory
when automatic discovery cannot find it. `PI_CODING_AGENT_DIR` overrides Pi's agent
directory (normally `.pi/agent` beneath the host's home directory).

The bridge runs as a supervised operation: streamed text and reasoning are forwarded,
tool calls return to the Lua agent, and cancellation/deadlines stop the process.
The model window is Pi's subscription catalog's 272,000 tokens, rather than assuming
the public API's larger window. Subscription access still depends on the account.

Risk: this intentionally depends on Pi's installed adapter API. Update Pi to a version
whose catalog includes the GPT-6 family; incompatible/missing dependencies fail visibly.
The graph audit does not resolve calls inside the embedded JavaScript string;
the bridge's offline contract test and real subscription exchanges cover that boundary.
