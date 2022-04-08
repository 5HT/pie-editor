-module(pie).
-author('Maxim Sokhatsky').    % Renaissance from 'ermacs' to 'pie'
-author('Luke Gorrie').        % Evolution from 'edit' to 'ermacs'
-author('Torbjorn Tornkvist'). % Oigirianl 'edit' program
-export([start/0]).
-include_lib("pie/include/edit.hrl").
-compile(export_all).

send(Pool, Message) -> gproc:send({p,l,Pool},Message).
reg(Pool) ->
    Ctx = get({pool,Pool}),
    case Ctx of
         undefined -> gproc:reg({p,l,Pool}), put({pool,Pool},Pool);
         Defined -> skip end.

start() ->
    application:start(sasl),
    application:start(crypto),
    application:start(tools),
    application:start(compiler),
    application:start(syntax_tools),
    application:start(lager),
    application:start(gproc),
    application:start(rebar),
    application:start(erlfsmon),
    application:start(active),
%    application:start(ucs),
    application:start(ux),
    init().

start(Args) -> 
    Filenames = lists:map(fun(X) -> atom_to_list(X) end, Args),
    lists:foreach(fun(Filename) -> self() ! {invoke, {edit_file, find_file, [Filename]}} end, Filenames),
    start().

%% API program

invoke_async(M, F, A, Proc) -> pie:send(loop,{invoke, {M, F, A}}).
invoke_async(Fn, Proc) -> pie:send(loop,{invoke, Fn}).
invoke_extended_async(M, F, A, Proc) -> pie:send(loop,{invoke_extended, {M, F, A}}).
get_key(Proc) -> pie:send(loop,{want_key, self()}), receive {key_input, Ch} -> Ch end.

%% Turn this process into a lean, mean, editing machine

init() ->
    register(?MODULE, self()),
    init_io_traps(),
    process_flag(trap_exit, true),
    %% Initialize editor
    edit_keymap:start_link_server(),
    edit_globalmap:init(),
    ?TERM:setup(),
    edit_input:start_link(self()),
    init_vars(),
    init_buffers(),
    init_mods(),
    State = init_windows(#state{}),
    State1 = load_dot_pie(State),
    State2 = redraw(State1),
    %%profile(State2),
    pie:reg(loop),
    loop(State2).

init_io_traps() ->
    {ok, Leader} = file_gl:start_link("/tmp/edit.out"),
    group_leader(Leader, self()),
    error_logger:tty(false).

%% Setup initial buffers (scratch and minibuffer)

init_buffers() ->
    edit_buf:new('*scratch*'),
    edit_buf:new(minibuffer),
    MBMode = #mode{name="Minibuffer", id=minibuffer, keymaps=[minibuffer_map]},
    edit_buf:set_mode(minibuffer, MBMode).

%% Setup initial windows

init_windows(State) ->
    Width = ?TERM:width(),
    Height = ?TERM:height(),
    ScratchWin = edit_window:make_window('*scratch*', 0, Width, Height - 1),
    MiniWin1 = edit_window:make_window(minibuffer, Height - 1, Width, 1),
    MiniWin2 = MiniWin1#window{active=false,  minibuffer=true},
    State#state{curwin=ScratchWin, buffers=['*scratch*'], windows=[MiniWin2]}.

init_minibuffer(State) ->
    edit_buf:new(minibuffer),
    State.

init_vars() ->
    edit_var:start_link(),
    edit_var:set(killring, []).

init_mods() ->
    edit_mod:init(),
    %% special-case explicit initialisations for the core stuffs
    em_erlang:mod_init(),
    edit_file:mod_init(),
    ok.

load_dot_pie(State) ->
    Filename = filename:join(os:getenv("HOME"), ".pie"),
    case file:read_file_info(Filename) of
        {error, _} -> edit_util:status_msg(State, "Nooo ~~/.pie to read. ~p",[now()]);
        {ok, _} ->
            case catch file:eval(Filename) of
                ok -> State;
                {error, Rsn} -> edit_util:status_msg(State, "~/.pie failed: ~p", [Rsn]) end end.

%% The Main Loop

loop(S) ->
    slang:block_signals(),
    {Curr,LastCursor} = edit_display:draw_window(S#state.curwin),
    slang:unblock_signals(),
    State = S#state{curwin=Curr,last_cursor=LastCursor},
    NewState = dispatch(State),
    ?MODULE:loop(redraw(NewState)).

redraw(State) ->
    slang:block_signals(),
    Wins = [ begin {Win,_} = edit_display:draw_window(W), Win end || W <- State#state.windows],
    {Cur,{X,Y}} = edit_display:draw_window(State#state.curwin),
    SM = State#state.selection_mode,
    SC = State#state.selection_changed,
    case State#state.selection of
         {XX,YY} ->  %error_logger:info_msg("Last: ~p Curr: ~p",[{XX,YY},{X,Y}]),
                     XMin=edit_lib:min(XX,X),
                     XMax=edit_lib:max(XX,X),
                     YMin=edit_lib:min(YY,Y),
                     YMax=edit_lib:max(YY,Y),
                     Up = fun(Y,YY) -> case YY < Y of true -> XX; false -> X end end,
                     Bt = fun(Y,YY) -> case YY > Y of true -> XX; false -> X end end,
                     case Y == YY of
                          true  -> ?TERM:selection(YMin,XMin,YMax-YMin+1,XMax-XMin+1); 
                          false -> ?TERM:selection(YMin,Up(Y,YY),1,Cur#window.width-Up(Y,YY)+1),
                                   ?TERM:selection(YMin+1,0,YMax-YMin-1,Cur#window.width),
                                   ?TERM:selection(YMax,0,1,Bt(Y,YY))
                     end;
         _ -> ok end,
    ?TERM:refresh(),
    slang:unblock_signals(),
    State#state{curwin=Cur,windows=Wins}.

%% Dispatch a command, based on the next message we receive.

dispatch(State) ->
    Buf = (State#state.curwin)#window.buffer,
    Keymaps = (edit_buf:get_mode(Buf))#mode.keymaps ++ [global_map],
    receive
        {invoke, {M, F, A}} -> dispatch_proc(State, fun() -> apply(M, F, [State | A]) end);
        {invoke, Fun} when function(Fun) -> dispatch_proc(State, fun() -> Fun(State) end);
        {invoke_extended, {Mod, Func, Args}} -> dispatch_extended(State, Mod, Func, Args);
        {key_input, Ch} ->
            SState = selection_changed(State,Ch),
            case find_cmd(SState, Keymaps, Ch) of
                unbound -> edit_util:status_msg(SState, "Unbound key");
                {Mod, Func, Args} -> dispatch_extended(SState, Mod, Func, Args);
                Other -> edit_util:status_msg(SState,"Bad binding: ~p~n",[Other])
            end;
        {'EXIT', _Someone, _SomeReason} -> dispatch(State);
        Other -> edit_util:status_msg(State, "Unexpected message: ~p~n", [Other]) end.

dispatch_extended(State, Mod, Func, Args) ->
    F = fun() -> edit_extended:extended_command(State, Mod, Func, Args) end,
    dispatch_proc(State, F).

selection_changed(State,Ch) ->
    Shift = edit_util:shift(Ch),
    SState = State#state{selection_mode = Shift},
    Window = State#state.curwin,
    Buf = edit_lib:buffer(State),
    Point = edit_buf:mark_pos(Buf, point),
    Keyname = edit_util:keyname(Ch),
    NewSelection = case State#state.selection_mode =:= Shift of false -> changed; true ->  preserved end,

    error_logger:info_msg("Selection: ~p ~p ~p ~p ~w",[NewSelection,Shift,Point,Keyname,Ch]),

    {NewState,Selection} = case {NewSelection,Shift} of
        {changed,false} -> {SState,ok};
         {changed,true} -> {SState=edit_lib:set_mark(SState),SState#state.last_cursor};
                      _ -> {SState,SState#state.selection} end,

    NewState#state{selection_changed=NewSelection,selection=Selection}.

copy(State) ->
    Buf = edit_lib:buffer(State),
    Mark = edit_buf:mark_pos(Buf, mark),
    Point = edit_buf:mark_pos(Buf, point),
    Region = edit_buf:get_region(Buf,Mark,Point),
    error_logger:info_msg("Copied: ~p",[Region]),
    State#state{selection = Region}.

paste(State = #state{selection=Selection}) when is_list(Selection) ->
    Buf = edit_lib:buffer(State),
    edit_buf:insert(Buf, State#state.selection, edit_buf:mark_pos(Buf, point));
paste(State = #state{selection=Selection}) ->
    error_logger:info_msg("Pasting Error: ~p",[Selection]), State.

%% Dispatch a command in a new process.
%% The process gets aborted if the user presses C-g.

dispatch_proc(State, CommandFun) ->
    Self = self(),
    F = fun() -> Result = CommandFun(), Self ! {result, self(), Result}end,
    Pid = spawn_link(F),
    dispatch_loop(State, Pid, false).

dispatch_loop(State, Pid, WantKey) ->
    receive
        {result, Pid, Result} -> Result;
        {key_input, $\^G} -> exit(Pid, user_abort), edit_util:status_msg(State, "Abort");
        {key_input, Ch} when WantKey == true -> Pid ! {key_input, Ch}, dispatch_loop(State, Pid, false);
        {want_key, Pid} when WantKey == false -> dispatch_loop(State, Pid, true);
        {'EXIT', Pid, {_,Reason}} -> edit_util:status_msg(State,"Dispatch error: ~s",[io_lib:format("~p",[Reason])]) end.

%% Keymap lookup

find_cmd(State, Keymaps) -> Ch = get_char(), find_cmd(State, Keymaps, Ch).
find_cmd(State, [], Ch) -> unbound;
find_cmd(State, [Keymap|Keymaps], Ch) ->
    case edit_keymap:lookup(Keymap, Ch) of
        {ok, {keymap, NewMap}} -> find_cmd(State, [NewMap]);
        {ok, Cmd} -> Cmd;
        unbound -> find_cmd(State, Keymaps, Ch) end.

get_char() -> receive {key_input, C} -> C end.
sleep(T) -> receive after T -> true end.

%% Profiling

profile(State) ->
    receive after 100 -> ok end,
    Procs = [edit|State#state.buffers],
    timer:start_link(),
    spawn_link(fun() -> analyse_loop(Procs) end).

analyse_loop(Procs) ->
    eprof:start(),
    profiling = eprof:profile(Procs),
    receive after 15000 -> eprof:total_analyse() end,
    analyse_loop(Procs).

%% Another command-line entry function. Starts the editor with some
%% modules loaded for debugging.

debug() ->
    lists:foreach(fun(Mod) -> i:ii(Mod) end, debug_modules()),
    i:im(),
    proc_lib:start_link(?MODULE, start, []).

debug_modules() ->
    [edit_display, edit_lib, ?TERM, edit_keymap, edit_buf,
     edit_extended, edit_file, cord, edit_eval, edit_util, edit_text].
