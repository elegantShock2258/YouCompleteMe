# Copyright (C) 2024 YouCompleteMe contributors
#
# This file is part of YouCompleteMe.
# ...GPL v3 license...

import logging
import time

from ycm import vimsupport
from ycm.client.base_request import BaseRequest, BuildRequestData
from ycmd.utils import ByteOffsetToCodepointOffset

_logger = logging.getLogger( __name__ )

_REQUEST_TIMEOUT_SEC = 3
_MIN_PREFIX_LENGTH = 3           # Don't request AI for < 3 chars typed.
_REQUEST_COOLDOWN_MS = 500       # Min gap between successive API calls.


class AiCompletionRequest:
  """Async, deduplicated bridge for AI code completions.

  Guarantees:
  - At most ONE request in flight at any time.
  - Stale responses (cursor moved, text changed) are silently dropped.
  - Same prefix at same position never re-requests (cache on server side).
  - Minimum prefix length before any request is sent.
  - Cooldown between requests to avoid hammering the API.
  """

  def __init__( self ):
    self._last_request_time = 0.0
    self._pending_future = None
    self._current_suggestion = ''

    # Generation counter — incremented on each new request.
    # Responses from old generations are discarded.
    self._generation = 0

    # Track what we last requested to avoid duplicates.
    self._last_prefix_hash = ''
    self._last_line = -1
    self._last_file = ''


  def RequestSuggestion( self ):
    """Non-blocking poll + dispatch. Called from VimL timer.

    Returns the current cached suggestion (may be '' if nothing ready).
    """
    # 1. Harvest completed future.
    if self._pending_future and self._pending_future.done():
      self._HarvestResponse()

    # 2. Maybe start a new request.
    now = time.time()
    if now - self._last_request_time >= _REQUEST_COOLDOWN_MS / 1000.0:
      self._MaybeStartRequest()

    return self._current_suggestion


  def CancelPending( self ):
    """Called when the user types — discard in-flight request."""
    if self._pending_future and not self._pending_future.done():
      self._generation += 1  # Invalidate the old generation.
      self._pending_future = None
      self._current_suggestion = ''


  def GetCurrentSuggestion( self ):
    return self._current_suggestion


  def Clear( self ):
    self.CancelPending()
    self._current_suggestion = ''


  # --- Internals ---

  def _HarvestResponse( self ):
    """Collect the completed future, discard if stale."""
    try:
      gen = self._generation
      http_response = self._pending_future.result()
      self._pending_future = None

      # Only use the response if no newer request was started.
      if gen != self._generation:
        _logger.debug( 'AI: discarding stale response (gen %d != %d)',
                       gen, self._generation )
        return

      # Parse JSON from the HTTP response body.
      import json
      body = http_response.read().decode( 'utf-8' )
      data = json.loads( body )
      suggestion = data.get( 'suggestion', '' )
      if suggestion:
        self._current_suggestion = suggestion
    except Exception:
      _logger.debug( 'AI: request failed, skipping' )
      self._current_suggestion = ''
    finally:
      self._pending_future = None


  def _MaybeStartRequest( self ):
    """Start a new async request if conditions are met."""
    # Minimum prefix length.
    prefix = vimsupport.TextBeforeCursor()
    if len( prefix ) < _MIN_PREFIX_LENGTH:
      return

    # Don't re-request the exact same prefix at the same position.
    try:
      line, _ = vimsupport.CurrentLineAndColumn()
      fname = vimsupport.GetCurrentBufferFilepath()
    except Exception:
      return

    prefix_hash = f'{ fname }:{ line }:{ prefix[ -60: ] }'
    if ( prefix_hash == self._last_prefix_hash
         and line == self._last_line
         and fname == self._last_file ):
      return  # Already requested this exact context.

    self._last_prefix_hash = prefix_hash
    self._last_line = line
    self._last_file = fname
    self._last_request_time = time.time()

    # Build params and fire.
    try:
      params = self._BuildRequestParams( prefix )
      if params is None:
        return
    except Exception:
      return

    self._generation += 1
    gen = self._generation

    try:
      self._pending_future = BaseRequest.PostDataToHandlerAsync(
          params, 'ai_completion', timeout=_REQUEST_TIMEOUT_SEC )

      # Tag the future with its generation so _HarvestResponse can check.
      self._pending_future._ai_gen = gen
    except Exception:
      _logger.exception( 'AI: failed to start request' )


  def _BuildRequestParams( self, prefix ):
    """Build request data for the /ai_completion endpoint."""
    try:
      request_data = BuildRequestData()
    except Exception:
      return None

    line_contents = vimsupport.CurrentLineContents()
    _, byte_column = vimsupport.CurrentLineAndColumn()
    column_codepoint = ByteOffsetToCodepointOffset(
        line_contents, byte_column + 1 ) - 1

    request_data[ 'line_value' ] = line_contents
    request_data[ 'column_codepoint' ] = column_codepoint
    request_data[ 'prefix' ] = prefix
    request_data[ 'suffix' ] = vimsupport.TextAfterCursor()
    request_data[ 'buffer_num' ] = vimsupport.GetCurrentBufferNumber()
    request_data[ 'filetypes' ] = vimsupport.CurrentFiletypes()

    return request_data


# --- Module-level singleton ---

_inst = None

def GetAiCompletionRequest():
  global _inst
  if _inst is None:
    _inst = AiCompletionRequest()
  return _inst


def SendAiCompletionRequest():
  """Called from Vim via py3eval. Non-blocking, deduplicated."""
  return GetAiCompletionRequest().RequestSuggestion()


def CancelAiCompletionRequest():
  """Called on TextChangedI to kill stale in-flight requests."""
  GetAiCompletionRequest().CancelPending()


def ClearAiSuggestion():
  GetAiCompletionRequest().Clear()
