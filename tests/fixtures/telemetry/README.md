# Telemetry fixtures

`trace-dual-core.fixture` is a synthetic two-core MPP trace and
`trace-rga.fixture` is a synthetic RGA lifecycle trace. Their host self-tests
require internally consistent queued/selected/started/completed chains. Todo 16
adds verbatim board captures beneath board-named directories:

- armed MPP `load` at idle, one session, and two sessions;
- MPP `sessions-summary` with two sessions;
- the RGA `load` file.

Those future files are hardware evidence. They must be copied byte-for-byte and
must not replace the synthetic parser fixture.
