" Copyright (C) 2024 YouCompleteMe contributors
"
" This file is part of YouCompleteMe.
"
" YouCompleteMe is free software: you can redistribute it and/or modify
" it under the terms of the GNU General Public License as published by
" the Free Software Foundation, either version 3 of the License, or
" (at your option) any later version.
"
" YouCompleteMe is distributed in the hope that it will be useful,
" but WITHOUT ANY WARRANTY; without even the implied warranty of
" MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
" GNU General Public License for more details.
"
" You should have received a copy of the GNU General Public License
" along with YouCompleteMe.  If not, see <http://www.gnu.org/licenses/>.

" ============================================================================
" File:        ai.vim
" Description: AI-powered ghost text suggestions (GitHub Copilot style) for
"              YouCompleteMe. Displays inline faded/italic ghost text after
"              the cursor that previews the next suggested code completion.
"
" Supported:   Vim 9.0+ (prop_add API) and Neovim 0.5+ (extmark API).
"
" Global settings (set in vimrc before YCM loads):
"   g:ycm_ai_enabled           - Enable/disable AI ghost text (default: 1)
"   g:ycm_ai_key_accept        - Key to accept suggestion  (default: '<Tab>')
"   g:ycm_ai_key_manual_trigger- Key to manually trigger    (default: '<M-/>')
"   g:ycm_ai_faded_color       - Hex colour for ghost text  (default: '#666666')
"   g:ycm_ai_debounce_ms       - Debounce delay in ms       (default: 300)
" ============================================================================

" This is basic vim plugin boilerplate
let s:save_cpo = &cpoptions
set cpoptions&vim

scriptencoding utf-8

" ============================================================================
" Global settings with sensible defaults
" ============================================================================

" Master switch: set to 0 to disable all AI ghost text functionality.
let g:ycm_ai_enabled = get( g:, 'ycm_ai_enabled', 1 )

" Key used to accept an active AI suggestion. When no suggestion is visible,
" the key falls through to its normal behaviour (e.g. Tab inserts a tab).
let g:ycm_ai_key_accept = get( g:, 'ycm_ai_key_accept', '<Tab>' )

" Key chord that manually triggers an AI completion request.
let g:ycm_ai_key_manual_trigger = get( g:, 'ycm_ai_key_manual_trigger', '<M-/>' )

" Colour for the faded/italic ghost text. Uses the same style as GitHub Copilot
" -- a dimmed gray that sits unobtrusively after the cursor.
let g:ycm_ai_faded_color = get( g:, 'ycm_ai_faded_color', '#666666' )

" Debounce interval in milliseconds. When the user types rapidly, we wait this
" long after the last keystroke before issuing a new AI completion request.
let g:ycm_ai_debounce_ms = get( g:, 'ycm_ai_debounce_ms', 300 )

" ============================================================================
" Script-local state variables
" ============================================================================

" Is an AI suggestion currently being displayed?
let s:ai_suggestion_active = 0

" The text of the current suggestion (used by AcceptSuggestion).
let s:ai_current_suggestion = ''

" --- Vim 9.0+ property types ---
" The ID of the prop_add() text property used to display ghost text in Vim.
" Stored so we can remove it later (either by type or by specific ID).
" Not used in Neovim (which uses extmark IDs instead).
let s:ai_prop_id = -1

" --- Neovim extmark ---
" The extmark ID returned by nvim_buf_set_extmark for the current ghost text.
" -1 means no extmark is active.
let s:ai_extmark_id = -1

" Timer ID for the debounce timer. -1 means no timer is pending.
let s:ai_debounce_timer = -1

" Detecting Neovim: Neovim reports v:version as 800, so we use has('nvim').
let s:is_neovim = has( 'nvim' )

" Neovim namespace ID for AI ghost text extmarks. Created once at load time.
" We use a separate namespace ('ycm_ai') so that AI extmarks do not interfere
" with other YCM extmarks (diagnostics, inlay hints, etc.) that use the
" main 'ycm_id' namespace.
let s:ai_namespace_id = s:is_neovim
      \ ? nvim_create_namespace( 'ycm_ai' )
      \ : -1

" ============================================================================
" Highlight group: YcmAISuggestion
"
" This creates a faded/italic highlight group that mimics GitHub Copilot's
" ghost text appearance. The suggestion text is shown in a dimmed gray colour
" with italic styling, so it is clearly distinguishable from actual code.
" ============================================================================

function! s:DefineAIHighlights()
  " Avoid redefining the highlight group if it already exists. This allows
  " users to customise the appearance by defining YcmAISuggestion in their
  " vimrc before YCM loads.
  if hlexists( 'YcmAISuggestion' )
    return
  endif

  if exists( '*hlget' )
    " Vim 9.0+ path: copy the Comment highlight and tint it to our faded colour.
    " This gives us all platform-specific terminal/X11 colour resolution for
    " free, while overriding the foreground to our custom faded colour.
    let l:ai_hl = hlget( 'Comment', v:true )[ 0 ]
    let l:ai_hl.name = 'YcmAISuggestion'
    let l:ai_hl.cterm = { 'fg': '8', 'italic': 1 }
    let l:ai_hl.gui = { 'fg': g:ycm_ai_faded_color, 'italic': 1 }
    call hlset( [ l:ai_hl ] )
  else
    " Fallback for older Vim and Neovim: define the highlight directly.
    execute 'highlight default YcmAISuggestion ctermfg=8 cterm=italic '
          \ . 'guifg=' . g:ycm_ai_faded_color . ' gui=italic'
  endif
endfunction

" ============================================================================
" Property type setup (Vim 9.0+ only)
"
" Defines the text property type used to attach ghost text to a buffer.
" The 'combine' flag is set to 0 so the ghost text highlight doesn't bleed
" into adjacent syntax-highlighted characters.
" ============================================================================

function! s:SetupPropType()
  " Only needed for Vim. Neovim uses extmarks.
  if s:is_neovim
    return
  endif

  " Guard against missing prop_type_add (Vim < 9.0 / Neovim).
  if !exists( '*prop_type_add' )
    return
  endif

  " Only define the type once.
  if index( prop_type_list(), 'YcmAISuggestion' ) >= 0
    return
  endif

  call prop_type_add( 'YcmAISuggestion', {
        \   'highlight': 'YcmAISuggestion',
        \   'combine':   0,
        \ } )
endfunction

" ============================================================================
" youcompleteme#ai#ShowSuggestion( suggestion_text )
"
" Displays the given text as faded ghost text immediately after the cursor.
" Uses Vim's prop_add() API (Vim 9.0+) or Neovim's nvim_buf_set_extmark().
"
" The ghost text sits inline after the cursor and is rendered in the
" YcmAISuggestion highlight group (grayed-out, italic).
"
" If a suggestion is already visible, it is silently replaced.
"
" Args:
"   suggestion_text : string - the text to display as ghost text
" ============================================================================

function! youcompleteme#ai#ShowSuggestion( suggestion_text )
  " Store the suggestion text for later acceptance.
  let s:ai_current_suggestion = a:suggestion_text

  " Bail out if the text is empty -- nothing to show.
  if empty( a:suggestion_text )
    call youcompleteme#ai#ClearSuggestion()
    return
  endif

  " Clear any previous suggestion before showing the new one.
  call youcompleteme#ai#ClearSuggestion()

  if s:is_neovim
    " ---- Neovim path: use nvim_buf_set_extmark ----
    " Neovim uses 0-based line and column numbers.
    " 'virt_text_pos': 'overlay' places the virtual text inline at the cursor.
    " 'hl_mode': 'combine' allows the highlight to layer with syntax colours.
    let l:bufnr = bufnr( '%' )
    let l:line = line( '.' ) - 1
    let l:col = col( '.' ) - 1

    " Use our dedicated AI namespace (s:ai_namespace_id), created at load time.
    " This keeps AI ghost text extmarks separate from the main YCM namespace.
    let l:ns_id = s:ai_namespace_id

    let s:ai_extmark_id = nvim_buf_set_extmark( l:bufnr,
          \ l:ns_id,
          \ l:line,
          \ l:col,
          \ {
          \   'virt_text': [ [ a:suggestion_text, 'YcmAISuggestion' ] ],
          \   'virt_text_pos': 'overlay',
          \   'hl_mode': 'combine',
          \   'priority': 100,
          \ } )
    let s:ai_suggestion_active = 1
  else
    " ---- Vim 9.0+ path: use prop_add ----
    " Ensure the property type is defined.
    call s:SetupPropType()

    " Add ghost text at end of line (column 0 required for
    " text_align 'after'). Shows the AI suggestion inline in
    " faded gray (GitHub Copilot style). Falls back to :echom
    " if Vim doesn't support prop_add.
    try
      let s:ai_prop_id = prop_add( line( '.' ),
            \ 0,
            \ {
            \   'type': 'YcmAISuggestion',
            \   'text': a:suggestion_text,
            \   'text_align': 'after',
            \ } )
      let s:ai_suggestion_active = 1
    catch /.*/
      echom '🤖 YCM AI: ' . a:suggestion_text
    endtry
  endif
endfunction

" ============================================================================
" youcompleteme#ai#ClearSuggestion()
"
" Removes any currently displayed ghost text from the buffer. This is called
" on cursor movement, typing, mode changes, and whenever the suggestion should
" be dismissed.
"
" It is safe to call this function even if no suggestion is visible.
" ============================================================================

function! youcompleteme#ai#ClearSuggestion()
  if s:is_neovim
    " ---- Neovim path ----
    if s:ai_extmark_id >= 0
      try
        call nvim_buf_del_extmark( bufnr( '%' ), s:ai_namespace_id,
              \ s:ai_extmark_id )
      catch
        " If the buffer is no longer valid or the extmark was already deleted,
        " ignore the error.
      endtry
      let s:ai_extmark_id = -1
    endif
  else
    " ---- Vim 9.0+ path ----
    if exists( '*prop_remove' )
      try
        " Remove all AI ghost text props from the current buffer.
        call prop_remove( {
              \ 'type': 'YcmAISuggestion',
              \ 'bufnr': bufnr( '%' ),
              \ 'all': v:true,
              \ } )
      catch /.*/
      endtry
    endif
    let s:ai_prop_id = -1
  endif

  let s:ai_suggestion_active = 0
  let s:ai_current_suggestion = ''
endfunction

" ============================================================================
" youcompleteme#ai#AcceptSuggestion()
"
" Accepts the currently visible AI suggestion: inserts the ghost text into the
" buffer at the cursor position and clears the ghost text display.
"
" Returns:
"   The accepted suggestion text (useful for use in mappings via <C-R>=).
"   Returns an empty string if no suggestion is active.
" ============================================================================

function! youcompleteme#ai#AcceptSuggestion()
  if !s:ai_suggestion_active || empty( s:ai_current_suggestion )
    return ''
  endif

  let l:text = s:ai_current_suggestion
  call youcompleteme#ai#ClearSuggestion()
  " Return the text so the <expr> mapping inserts it.
  " Do NOT use feedkeys() here — the expr mapping handles insertion.
  return l:text
endfunction

" ============================================================================
" youcompleteme#ai#RequestSuggestion()
"
" Manually triggers an AI completion request. This communicates with the ycmd
" server via the Python bridge (which handles the actual AI/LLM request).
"
" This is intended to be bound to a key mapping (default: <M-/>) so the user
" can request a suggestion on demand.
"
" Returns:
"   An empty string (for use in <C-R>= mappings).
" ============================================================================

function! youcompleteme#ai#RequestSuggestion()
  if !g:ycm_ai_enabled
    return ''
  endif

  " Check that we are in a buffer where YCM is active.
  if !exists( '*youcompleteme#filetypes#AllowedForFiletype' )
    return ''
  endif

  let l:ft = &filetype
  if empty( l:ft )
    let l:ft = 'ycm_nofiletype'
  endif
  if !youcompleteme#filetypes#AllowedForFiletype( l:ft )
    return ''
  endif

  " Request an AI completion from the ycmd server through the Python bridge.
  " The Python function ycm_state.RequestAICompletion() is expected to:
  "   1. Send a request to ycmd's AI/copilot endpoint
  "   2. Return the suggestion text (or empty if unavailable)
  "
  " We wrap the Python call in try/except to avoid backtraces.
  try
    let l:suggestion = py3eval( 'ycm_state.RequestAICompletion()' )
  catch
    let l:suggestion = ''
  endtry

  if !empty( l:suggestion )
    call youcompleteme#ai#ShowSuggestion( l:suggestion )
  endif

  return ''
endfunction

" ============================================================================
" youcompleteme#ai#OnTextChanged()
"
" Called on the TextChangedI autocommand whenever the user types in insert
" mode. This function:
"   1. Clears any existing ghost text (the user is typing something different)
"   2. Starts a debounce timer; once the user pauses typing for
"      g:ycm_ai_debounce_ms milliseconds, a new AI suggestion is requested.
"
" The debounce prevents overwhelming the server with requests on every
" keystroke.
" ============================================================================

function! youcompleteme#ai#OnTextChanged()
  if !g:ycm_ai_enabled
    return
  endif

  " Clear any visible ghost text -- the user's keystroke invalidates it.
  call youcompleteme#ai#ClearSuggestion()

  " Kill any in-flight AI request — user is typing, old request is stale.
  try
    call py3eval( 'ycm_state.CancelAICompletion()' )
  catch
  endtry

  " Stop any pending debounce timer.
  if s:ai_debounce_timer >= 0
    call timer_stop( s:ai_debounce_timer )
    let s:ai_debounce_timer = -1
  endif

  " Only start a timer if we have enough typed text.
  let l:col = col( '.' )
  if l:col < 3
    return
  endif

  " Start a new debounce timer.
  let s:ai_debounce_timer = timer_start(
        \ g:ycm_ai_debounce_ms,
        \ function( 's:AIDebounceCallback' ) )
endfunction

" ============================================================================
" s:AIDebounceCallback( timer_id )
"
" Internal callback for the debounce timer. Fires after the user has stopped
" typing for the debounce interval. Requests an AI suggestion from the ycmd
" server and displays it as ghost text.
"
" Args:
"   timer_id : number - the Vim timer ID (unused, but required by timer API)
" ============================================================================

function! s:AIDebounceCallback( timer_id )
  let s:ai_debounce_timer = -1

  " Double-check we are still in insert mode and YCM is enabled.
  if !g:ycm_ai_enabled
    return
  endif

  " Only request suggestions in insert mode.
  if mode() !=# 'i' && mode() !=# 'R'
    return
  endif

  " Request the AI suggestion via the Python bridge (non-blocking).
  try
    let l:suggestion = py3eval( 'ycm_state.RequestAICompletion()' )
  catch /.*/
    let l:suggestion = ''
  endtry

  if !empty( l:suggestion )
    echom 'YCM AI: got suggestion (' . len( l:suggestion ) . ' chars)'
    call youcompleteme#ai#ShowSuggestion( l:suggestion )
  else
    " No result yet — the async request may still be in flight.
    " Poll again in 150ms to check for the response.
    let s:ai_debounce_timer = timer_start(
          \ 150,
          \ function( 's:AIDebounceCallback' ) )
  endif
endfunction

" ============================================================================
" youcompleteme#ai#OnCursorMoved()
"
" Called on the CursorMovedI autocommand. If the cursor has moved, any visible
" ghost text is cleared because the suggestion is no longer relevant at the
" new cursor position.
"
" This provides the same behaviour as GitHub Copilot -- moving the cursor
" dismisses the current suggestion.
" ============================================================================

function! youcompleteme#ai#OnCursorMoved()
  if !g:ycm_ai_enabled
    return
  endif

  " Clear any visible suggestion when the cursor moves. The suggestion is
  " tied to the previous cursor position and would be misleading if kept.
  if s:ai_suggestion_active
    call youcompleteme#ai#ClearSuggestion()
  endif
endfunction

" ============================================================================
" Key mappings
"
" These mappings integrate AI ghost text suggestions with the keyboard:
"   - <Tab> (or g:ycm_ai_key_accept):
"       Accept the suggestion if one is visible; otherwise fall through to
"       normal Tab behaviour (including YCM's popup menu navigation).
"   - <M-/> (or g:ycm_ai_key_manual_trigger):
"       Manually request an AI suggestion.
"   - <Esc>:
"       Clear the popup menu (if visible) AND dismiss the ghost text before
"       leaving insert mode.
" ============================================================================

function! youcompleteme#ai#SetupMappings()
  if !g:ycm_ai_enabled
    return
  endif

  " --- Tab / Accept key ---
  " Use an <expr> mapping so we can conditionally accept the suggestion or
  " pass through to normal Tab behaviour.
  execute 'inoremap <expr> <silent> ' . g:ycm_ai_key_accept .
        \ ' youcompleteme#ai#AcceptOrTab()'

  " --- Manual trigger key ---
  " Uses <C-R>= to call the function and insert its return value (empty
  " string) into the buffer.
  execute 'inoremap <silent> ' . g:ycm_ai_key_manual_trigger .
        \ ' <C-R>=youcompleteme#ai#RequestSuggestion()<CR>'

  " --- Escape key ---
  " When the popup menu is visible, first close it with <C-e>, then leave
  " insert mode. Also clear any visible ghost text before leaving insert
  " mode (in case InsertLeave autocmd doesn't fire in time).
  inoremap <expr> <silent> <Esc> pumvisible()
        \ ? "\<C-e>\<Esc>"
        \ : youcompleteme#ai#ClearSuggestionWrapper() . "\<Esc>"
endfunction

" ============================================================================
" youcompleteme#ai#AcceptOrTab()
"
" Expression mapping helper: if an AI suggestion is currently visible, accept
" it. Otherwise, return a literal Tab key for normal usage (including YCM
" popup menu navigation).
"
" Returns:
"   The suggestion text (for insertion) if active, or "\<Tab>" otherwise.
" ============================================================================

function! youcompleteme#ai#AcceptOrTab()
  if s:ai_suggestion_active
    return youcompleteme#ai#AcceptSuggestion()
  endif
  return "\<Tab>"
endfunction

" ============================================================================
" youcompleteme#ai#ClearSuggestionWrapper()
"
" Wrapper function for use in <expr> mappings. Calls ClearSuggestion() and
" always returns an empty string so the mapping does not insert any text.
"
" This is needed because <expr> mappings expect a string return value, and
" calling ClearSuggestion() directly as a <C-R>= expression works but is
" more verbose.
" ============================================================================

function! youcompleteme#ai#ClearSuggestionWrapper()
  call youcompleteme#ai#ClearSuggestion()
  return ''
endfunction

" ============================================================================
" youcompleteme#ai#Enable()
"
" Activates AI ghost text completion. Called during YCM initialisation (or
" manually by the user).
"
" This function:
"   1. Defines the YcmAISuggestion highlight group
"   2. Sets up the Vim text property type (Vim only)
"   3. Registers autocommands for TextChangedI, InsertLeave, and CursorMovedI
"   4. Installs key mappings
"   5. Initialises script-local state
" ============================================================================

function! youcompleteme#ai#Enable()
  if !get( g:, 'ycm_ai_enabled', 0 )
    echom 'YCM AI: disabled (g:ycm_ai_enabled = 0)'
    return
  endif
  echom 'YCM AI: enabling ghost text...'

  " Set up visual appearance.
  call s:DefineAIHighlights()
  if !s:is_neovim
    call s:SetupPropType()
  endif

  " Install key mappings.
  call youcompleteme#ai#SetupMappings()

  " Register autocommands for the AI completion flow.
  " We use a separate augroup so that Disable() can remove all of them at once.
  augroup ycmaicompletion
    autocmd!
    " On every text change in insert mode, clear the old suggestion and
    " schedule a new one (with debounce).
    autocmd TextChangedI * call youcompleteme#ai#OnTextChanged()

    " When leaving insert mode, clear the ghost text suggestion.
    autocmd InsertLeave * call youcompleteme#ai#ClearSuggestion()

    " When the cursor moves in insert mode, clear the suggestion (it is no
    " longer relevant at the new position).
    autocmd CursorMovedI * call youcompleteme#ai#OnCursorMoved()
  augroup END

  " Initialise state.
  let s:ai_suggestion_active = 0
  let s:ai_current_suggestion = ''
  let s:ai_prop_id = -1
  let s:ai_extmark_id = -1
  let s:ai_debounce_timer = -1
endfunction

" ============================================================================
" youcompleteme#ai#Disable()
"
" Deactivates AI ghost text completion. Removes all autocommands, clears any
" visible ghost text, and resets internal state.
" ============================================================================

function! youcompleteme#ai#Disable()
  " Remove any ghost text currently displayed.
  call youcompleteme#ai#ClearSuggestion()

  " Stop any pending debounce timer.
  if s:ai_debounce_timer >= 0
    call timer_stop( s:ai_debounce_timer )
    let s:ai_debounce_timer = -1
  endif

  " Remove all autocommands in the ycmaicompletion augroup.
  augroup ycmaicompletion
    autocmd!
  augroup END

  " Reset state.
  let s:ai_suggestion_active = 0
  let s:ai_current_suggestion = ''
  let s:ai_prop_id = -1
  let s:ai_extmark_id = -1
endfunction

" ============================================================================
" Cleanup boilerplate
" ============================================================================

let &cpoptions = s:save_cpo
unlet s:save_cpo
