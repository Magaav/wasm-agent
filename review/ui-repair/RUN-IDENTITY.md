# Run identity contract work in progress

`run_key` is canonical positive decimal text. Existing numeric run_id remains compatibility output only. Requests accept decimal-string run_id or legacy safe numeric run_id. Invalid/noncanonical returns invalid_run_id; unsafe legacy numeric returns unsafe_numeric_run_id; overflow or values outside signed SQLite journal range returns run_id_out_of_range. Persistence supports 1..9223372036854775807, not full u64. Owner/conversation auth remains unchanged.

Implementation is incomplete: remaining thread/event/admission emission sites and UI callers still require conversion and route fixture proof. Do not use this note as acceptance evidence.
