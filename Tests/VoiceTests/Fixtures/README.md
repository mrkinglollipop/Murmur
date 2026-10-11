# Stitch replay fixtures

All fixtures contain invented text and timestamps; no recordings or private
transcripts belong here. `StitchReplayTests.testReplayAllFixtures` loads every
bundled `stitch-*.json` and creates a fresh, offline transcriber for each.

When a production stitch bug is found, run the app with `VOICE_DEBUG=1` and
reproduce it. Use the `xai-stream:` event diagnostics to identify ordering,
finalization, and timestamp boundaries. Those logs intentionally omit transcript
text, so they cannot be mechanically converted into complete replay JSON.
Recreate the event sequence with synthetic text and timestamps instead; never
copy private transcript text or recordings. Add the fixture before fixing the
bug so the fix is regression-locked.

Each JSON has `name`, `events`, and `expected`. Events have `type` (`final` or
`interim`), `text`, `speechFinal`, and `words` (`text`, `start`, `end`, in seconds).
Optional `expectedAfter` asserts the merged transcript immediately after an
event, including a stale interim before a speech-final clears it. Final events
call the real ingestion seam; interim events use the real server-event handler.

The first five regression fixtures adapt the shapes covered by
`testMattProjectLollipopGolden`, `testMattAlwaysOnRuleThinkFirstGolden`,
`testMattCursorFromItGoldenCollapsesWithADETrailer`,
`testMattConnectCursorIntoNotionGolden`, and the Fireclaw/FireCrawl overlapping
tail cases in `StitchDedupeTests`, with wholly invented wording.
If a previously fixed regression disagrees with ingestion, document it and
mark that fixture with a named `XCTSkip` in the harness; do not change the stitch
algorithm or weaken its expected result to make this infrastructure pass.

Round 2 text safety: replacement fixtures include overlapping word timestamps;
their expected corrected text is unchanged. Untimed and disjoint-prefix fixtures
preserve both completed sentences. Text-only unit goldens now preserve sentences;
these timestamped replays retain coverage for actual same-audio refinements.

Round 3 adds `done` events through the server handler and synthetic replays for
untimed interim tails, non-monotonic words, misaligned incoming words, and
utterance-local timestamp resets. The missing-timestamp ruling now also
preserves unfinished confirmed fragments: `chunk-overlap` and
`speech-final-containment` retain both segments instead of permitting text-only
replacement. The three untimed overlap/repetition cases in
`GoldenTranscriptTests` likewise assert preservation; they no longer authorize
deletion on text similarity. Same-utterance timestamped refinement expectations
remain intact.

The xAI `transcript.done` fixtures exercise the provider's full-session
completion: an owned interim may be replaced, a timed done may cover multiple
final utterances, and an utterance final may own its immediately preceding
untimed chunk. A nonempty done that conflicts without provenance latches
buffered-audio recovery while preserving the conservative stitched text. The
distinct-utterance fixture also locks intentional repetitions and materially
different wording against text-similarity deletion.

`StitchReplayTests` reads source fixtures in addition to bundled fixtures so a
test-first stitch repair can execute newly checked-in JSON without a generated
project-file edit. Required fixture names are asserted explicitly; a fixture
that is present but never replayed is a test failure.

The follow-up acceptance rows distinguish an unopposed or exact token-prefix
full-session done from ambiguity; preserve untimed repetitions after a
`speech_final` boundary; reject malformed word payloads and character-only
prefixes; and promote unresolved provisional interims when an empty done ends
the session. These rows also verify that a last-chunk refinement cannot clear
an unrelated earlier ambiguity.

`transcript.done` is documented by xAI as one full-session completion after
`audio.done`. A nonmatching short done with reset timestamp origins is not
permission to append guessed new speech: retain confirmed text and request
buffered-audio recovery.

Prefix proofs preserve lexical and numeric meaning: `-100` is not `100`,
`can` is not `can't`, and `3` is not `3.5`. A sentence terminal can complete
an exact prefix only when followed by whitespace or the end of the transcript.
