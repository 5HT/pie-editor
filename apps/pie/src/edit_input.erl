-module(edit_input).
-author('maxim@synrc.com').
-include_lib("pie/include/edit.hrl").
-export([start_link/1, loop/2]).

%% Receiver will be sent {key_input, Char} each time a key is pressed.
start_link(Receiver) ->
    Pid = spawn_link(edit_input, loop, [[],Receiver]),
    register(?MODULE, Pid),
    Pid.

loop(Acc,Receiver) ->
    Read = ?TERM:read(),
    
    Ch = case Read of
        $\n -> $\r;
        145 -> panic(); % C-M-q is reserved for panic 
        208 -> [208,?TERM:read()];
        209 -> [209,?TERM:read()];
        219 -> case ?TERM:read() of
                    53 -> [219,53,?TERM:read()]; % Fn-UP
                    54 -> [219,54,?TERM:read()]; % Fn-DOWN
                    49 -> ?MODULE:loop([219,49],Receiver);
                    65 -> [219,65];
                    66 -> [219,66];
                    67 -> [219,67];
                    68 -> [219,68];
                    70 -> [219,70]; % xterm
                    72 -> [219,72]; % xterm
                    X -> error_logger:info_msg("Read: ~p",[X]),
                         Receiver ! {key_input, 219},
                         X end;
        59 -> case ?TERM:read() of
                    54 -> Acc ++ [59,54,?TERM:read()]; % SHIFT+CTRL+CURSOR
                    53 -> Acc ++ [59,53,?TERM:read()]; % CTRL+CURSON
                    52 -> Acc ++ [59,52,?TERM:read()]; % SHIFT+ALT+CURSOR
                    51 -> Acc ++ [59,51,?TERM:read()]; % SHIFT+ALT+CURSOR
                    50 -> Acc ++ [59,50,?TERM:read()]; % SHIFT+CURSOR
                    X -> Receiver ! {key_input, Acc ++ [59]},
%                        error_logger:info_msg("Input Char [59]: ~p",[Ch]),
                           X end;
        207 -> case ?TERM:read() of
                    70 -> [207,70]; % Fn-RIGHT
                    72 -> [207,72]; % Fn-LEFT
                    X -> Receiver ! {key_input, 207},
                         X end;
        XXX -> XXX end,
    Receiver ! {key_input, Ch},
    ?MODULE:loop([],Receiver).

panic() -> halt().
