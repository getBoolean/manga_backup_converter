/// Time limits every host shares, named once (KTD4).
library;

/// Seconds of [hostRequestTimeout] (for limits derived from it in constant
/// expressions).
const int hostRequestTimeoutSeconds = 30;

/// A host's bound on one source network request that names no timeout of
/// its own (Paperback's `PaperbackHttp`; 0.9 requests never name one). It
/// also bounds how long a request held for a worker's replacement waits
/// before it proceeds unchanged: a held request never waits longer than the
/// request itself could.
const Duration hostRequestTimeout = Duration(seconds: hostRequestTimeoutSeconds);
