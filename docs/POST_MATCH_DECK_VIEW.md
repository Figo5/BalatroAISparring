# Post-match AI deck inspection

The human result screen uses Multiplayer's existing **View Decks** button.
The opponent tab shows the AI's final playing cards, including enhancements,
editions and seals; the other tab shows the human's deck. The existing Joker
display remains available on the result screen. This is a final collection,
not a replay, draw order, or a display of the AI's deck during play.

The native end screen requests `getNemesisDeck`, the pinned local server
relays it to the opponent, and the opponent's native handler serializes its
own `G.playing_cards` with `MP.UTILS.card_to_string`. The human's native receiver
loads those cards into `MP.nemesis_cards`. The deck overlay temporarily uses
that collection for the normal deck renderer and restores the human's own
`G.playing_cards` reference afterwards. No custom game renderer or server
action is introduced.

The send guard permits the request only from the trusted human role and the
response only from the trusted AI role, after a legitimately started match
has completed. Ghost replay, lobby departure and a reset match object close
the gate. The AI cannot request the human's private build, including after the
match. Deck responses do not enter AIObservation; the policy still receives
an empty observation at `MATCH_COMPLETE`. Ranked reports and stats exchange
remain blocked.

Verification extends the runtime lifecycle/role matrix on Lua 5.1 and LuaJIT,
executes the pinned native serializer and request behind the actual guard,
and executes the native receiver and both deck tabs on LuaJIT. Poisoned reads
reject access to draw-pile and RNG state. The real upstream server contract
tests verify the deck request/response relay after either player's loss.
The existing host retention keeps the AI process available for end-screen
requests until the human exits; a human playtest of the newly installed build
is required to confirm the final screen visually.
