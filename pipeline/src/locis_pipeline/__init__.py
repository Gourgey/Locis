"""Locis data pipeline: D-TRO ingestion, normalisation and static tile publishing."""

# Version of the tile/manifest format written by this pipeline. The iOS app refuses
# (shows everything as unknown) when it meets a format it does not understand.
TILE_FORMAT_VERSION = 1

# Lowest rules-engine version in the app that may interpret this data. Raise it when
# the normalised rules gain semantics that older app versions would misread.
MIN_ENGINE_VERSION = 1
