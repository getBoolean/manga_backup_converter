package mangabackup.tachi.extensions

/** An artifact failed integrity, trust or compatibility checks (`artifact-incompatible`). */
class ArtifactException(message: String, cause: Throwable? = null) : Exception(message, cause)

/** The artifact's extension API version is not hosted (`unsupported-api`). */
class UnsupportedApiException(message: String) : Exception(message)

