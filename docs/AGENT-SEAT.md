# The seat - what a harness must be for an agent to work well in it (design, 19/11)

wa is built for the agent that sits in it - any model. Every harness change is judged against these. A fix that only works for
one model, or that guesses what the model meant, is not done.

0. **The simplest change that works wins; measure it before building more** (Victor 19/11). Try the one-line fix first - a
   sentence of guidance, one generic continue, a default - measure it, and build machinery only for what it does not fix.
1. **No silent loss.** Every action the model sends is run, or the model is told exactly why not and what to do next (a named,
   counted notice). A turn never ends "answered" on an unexecuted action or a plan, and never fails without saying why.
2. **Model-agnostic action.** One CodeAct protocol with two transports - a fenced `run` block in the answer, or a native
   `run(code)` tool call. Which one a model uses is chosen from its measured profile (7), never hard-coded per model name.
3. **Adapters normalize, the core never guesses.** Each provider adapter turns its stream into one normalized message: answer
   text, reasoning, tool calls, finish reason. The core reads only that. A provider quirk is fixed in its adapter. Code is never
   executed from reasoning.
4. **Bytes travel exactly.** File bodies and patches go in raw blocks, never escaped inside code. A read says when it was
   truncated; a write after a truncated read refuses.
5. **Waiting is free, long work has one path.** No wall clock on a waiting script; long work starts as an operation and is
   awaited; a pending call always returns its operation id.
6. **Errors tell the truth and the fix.** A refusal names the real cause and the one action that resolves it, and comes before the
   effect, never after.
7. **Models are measured, not assumed.** A conformance suite (recorded tasks: acts in the answer, uses tool calls, closes fences,
   keeps the user's language, finishes with a real answer, survives a cut response) runs against any model and stores its
   profile; transport and guidance come from the profile. A new model is measured before it is trusted with missions.
8. **Friction is signal.** The model reports what hurt in every turn; the harness keeps it out of the answer, stores it, ranks it
   (`wa turns`) and the evolution log tracks it until it stops hurting.
9. **Changes roll out like deploys.** A new mode or guidance goes to one session first, is measured, then the fleet.
