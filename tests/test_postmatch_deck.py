"""Exercise the pinned Multiplayer deck producer, receiver and viewer.

Dependency sources stay local and untracked. Run --require-all for release
verification; ordinary source-only checkouts report a missing fixture explicitly.
The Lua engine boundary and server relay are tested separately in their suites.
"""
from pathlib import Path
import argparse
import importlib

ROOT = Path(__file__).resolve().parents[1]
MP = ROOT / 'work/local-ownership/native-mods-source/Multiplayer'


def section(source, start, stop):
    return source[source.index(start):source.index(stop, source.index(start))]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--require-all', action='store_true')
    args = parser.parse_args()
    if not MP.is_dir():
        if args.require_all:
            raise RuntimeError('Pinned Multiplayer source required for release verification')
        print('SKIP: pinned local Multiplayer source missing')
        return
    handlers = (MP / 'networking/action_handlers.lua').read_text(encoding='utf-8')
    utils = (MP / 'lib/card_utils.lua').read_text(encoding='utf-8')
    ui = (MP / 'ui/game/game_end.lua').read_text(encoding='utf-8')
    functions = (MP / 'ui/game/functions.lua').read_text(encoding='utf-8')
    producer = section(handlers, 'local function action_get_nemesis_deck()', 'local function action_send_game_stats()')
    receive = section(handlers, 'local function action_receive_nemesis_deck(p)', '-- Dual-call:')
    loader = section(handlers, 'function G.FUNCS.load_nemesis_deck()', 'local function action_receive_nemesis_deck(p)')
    serialize = section(utils, 'local reversed_centers = nil', 'function MP.UTILS.joker_to_string')
    request = section(handlers, 'function MP.ACTIONS.get_nemesis_deck()', '\nend') + '\nend\n'
    view = section(ui, 'function G.UIDEF.view_nemesis_deck()', '-- Contains function overrides')
    callback = section(functions, 'function G.FUNCS.view_nemesis_deck()', 'function G.FUNCS.open_kofi')
    assert 'getNemesisDeck = action_get_nemesis_deck' in handlers
    assert 'receiveNemesisDeck = action_receive_nemesis_deck' in handlers
    assert 'MP.ACTIONS.get_nemesis_deck()' in ui
    assert 'button = "view_nemesis_deck"' in ui
    assert 'text = localize("b_view_nemesis_deck")' in ui
    assert 'G.deck' not in producer and 'G.GAME' not in producer
    for runtime in ('lupa.lua51', 'lupa.luajit21'):
        lua = importlib.import_module(runtime).LuaRuntime(unpack_returned_tuples=True)
        lua.execute('''
            local base, enhanced = {}, {}
            G={P_CENTERS={m_base=base,m_bonus=enhanced}, FUNCS={}, UIDEF={},
                STAGES={MAIN_MENU=1,RUN=2},STATES={SELECTING_HAND=1,GAME_OVER=4},STAGE=1,STATE=1,
                playing_cards={
                    {base={suit='Spades',value='Ace'},config={center=base}},
                    {base={suit='Hearts',value='10'},config={center=enhanced},edition={foil=true},seal='Red'}
                }}
            -- Any attempt to serialize draw order or run/RNG state fails.
            setmetatable(G,{__index=function(_,k) error('private read: '..k) end})
            MP={UTILS={},ACTIONS={},LOBBY={code='LOCAL'},GAME={won=false},GHOST={is_active=function() return false end}}
            function MP.UTILS.reverse_key_value_pairs(t, strings)
                local out={}; for k,v in pairs(t) do out[strings and tostring(v) or v]=k end;return out
            end
            sent={};Client={send=function(p) sent[#sent+1]=p;return true end}
        ''')
        driver = lua.execute((ROOT / 'AISparring/integration/mp_driver.lua').read_text())
        lua.globals().driver_module = driver
        lua.execute('''
            ai=driver_module.factory({role='ai',mp=MP,G=G,client=Client,funcs={}})
            assert(ai.install_send_guard())
        ''')
        lua.execute(serialize + producer + '\nproduce=action_get_nemesis_deck')
        lua.execute('''
            produce(); assert(#sent==0)
            G.STAGE=G.STAGES.RUN; assert(ai.is_started()); produce();assert(#sent==0)
            G.STATE=G.STATES.GAME_OVER;produce();assert(#sent==1)
            assert(sent[1].action=='receiveNemesisDeck')
            assert(sent[1].cards==';S-A-m_base-none-none;H-T-m_bonus-foil-Red')
            payload=sent[1]; ai.uninstall(); sent={}
            human=driver_module.factory({role='human',mp=MP,G=G,client=Client,funcs={}})
            assert(human.install_send_guard()); assert(human.is_started())
            MP.GAME={won=false};G.STATE=1
        ''')
        lua.execute(request)
        lua.execute('''
            MP.ACTIONS.get_nemesis_deck();assert(#sent==0)
            MP.GAME.won=true;MP.ACTIONS.get_nemesis_deck()
            assert(#sent==1 and sent[1].action=='getNemesisDeck' and sent[1].cards==nil)
            produce();assert(#sent==1) -- Human private build cannot be sent.
        ''')
        if runtime.endswith('luajit21'):
            # The real dependency loader uses goto, supported by its native LuaJIT.
            lua.execute('''
                G.SETTINGS={};G.P_CARDS={S_A={},H_T={}};G.P_SEALS={Red={}}
                G.P_CENTERS.e_foil={};MP.nemesis_cards={};MP.nemesis_deck={}
                function MP.UTILS.string_split(s, sep)
                    local out={};for token in string.gmatch(s,'[^'..sep..']+') do out[#out+1]=token end;return out
                end
                function create_playing_card(spec,area)
                    assert(area==MP.nemesis_deck)
                    local c={front=spec.front,center=spec.center}
                    function c:set_edition(e) self.edition=e end
                    function c:set_seal(s) self.seal=s end
                    G.playing_cards[#G.playing_cards+1]=c;return c
                end
                function sendDebugMessage() error('Unexpected invalid card') end
                human_cards=G.playing_cards
                function G.UIDEF.view_deck() return G.playing_cards end
                function localize(k) return k end
                function create_tabs(t) return t end
                function create_UIBox_generic_options(t) return t end
                function G.FUNCS.overlay_menu(t) overlay=t.definition end
                G.deck_preview=false
            ''')
            lua.execute(loader + receive + '\nreceive=action_receive_nemesis_deck')
            lua.execute(view + callback)
            lua.execute('''
                receive(payload)
                assert(MP.nemesis_deck_received and #MP.nemesis_cards==2)
                assert(G.playing_cards==human_cards and #human_cards==2)
                assert(MP.nemesis_cards[1].front==G.P_CARDS.S_A)
                assert(MP.nemesis_cards[2].center==G.P_CENTERS.m_bonus)
                assert(MP.nemesis_cards[2].edition.foil and MP.nemesis_cards[2].seal=='Red')
                G.FUNCS.view_nemesis_deck()
                assert(G.SETTINGS.paused and overlay.back_func=='overlay_endgame_menu')
                local tabs=overlay.contents[1].tabs
                assert(tabs[1].chosen and tabs[1].label=='k_nemesis_deck')
                assert(tabs[1].tab_definition_function()==MP.nemesis_cards)
                assert(G.playing_cards==human_cards)
                assert(tabs[2].tab_definition_function()==human_cards)
                G.FUNCS.load_nemesis_deck();assert(#MP.nemesis_cards==2 and #human_cards==2)
            ''')
        print('PASS:', runtime, 'native deck serialization, guarded roles and post-match lifecycle' +
              ('; native receiver and View Decks tabs' if runtime.endswith('luajit21') else ''))
    print('RESULT: PASS')


if __name__ == '__main__':
    main()
