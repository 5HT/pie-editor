-module(edit_display).
-copyright('Luke Gorrie 16 Sep 2000').
-include_lib("pie/include/edit.hrl").
-compile(export_all).

draw_window(Window) when Window#window.minibuffer == true, Window#window.status_text /= undefined ->
    ?TERM:move_to(0, Window#window.y),
    draw_line(Window#window.status_text),
    {Window#window{status_text=undefined},{0,Window#window.y}};
draw_window(Window) -> try_update(Window).

try_update(Window) ->
    Buf = Window#window.buffer,
    PointMax = edit_buf:point_max(Buf),
    DStart = edit_buf:mark_pos(Buf, Window#window.start_mark),
    Scan = edit_lib:beginning_of_line_pos(Buf, DStart),
    Point = edit_buf:mark_pos(Buf, point),
    Chars = (?TERM:width() * ?TERM:height()) * 4, %% FIXME
    Text = edit_buf:get_region(Buf, Scan, min(PointMax, Scan + Chars)),
    ?TERM:move_to(0, Window#window.y),
    Rows = edit_window:text_lines(Window),
    Prefix = Window#window.prefix,
    PLen = length(Prefix),
    PAcc = lists:reverse(Prefix),
    case try_update_loop(Text,Rows,Scan,PLen,0,Point,undefined,PAcc) of
	{X, Y} ->
	    %% draw mode line
	    draw_modeline(Window),
	    TrimX = edit_lib:min(X, Window#window.width - 1),
            XX = TrimX,
            YY = Y + Window#window.y,
	    ?TERM:move_to(TrimX, Y + Window#window.y),
%            error_logger:info_msg("Cursor: ~p",[{XX,YY}]),
	    {Window,{XX,YY}};
	undefined ->
	    %% The point wasn't inside the area we drew, so we
	    %% recenter the display with the point in the middle and
	    %% then draw again.
	    try_update(recenter_window(Window))
    end.

%% Returns the location of the point in a tuple {X, Y}, or undefined
%% if it wasn't in the area drawn.

try_update_loop(Text, NRows, Scan, Col, Row, Point, PointXY, Acc) when Scan == Point, PointXY == undefined ->
    try_update_loop(Text,NRows,Scan,Col,Row,Point,{Col, Row},Acc);
try_update_loop([$\n|T], NRows, Scan, Col, Row, Point, PointXY, Acc) ->
    draw_line(lists:reverse(Acc)),
    ?TERM:newline(),
    NextRow = Row+1,
    if NextRow == NRows ->
	    PointXY;
       true ->
	    try_update_loop(T,NRows,Scan+1,0,Row+1,Point,PointXY, [])
    end;
try_update_loop([$\t|T], NRows, Scan, Col, Row, Point, PointXY, Acc) ->
    Size = 8 - (Col rem 8),
    Tab = lists:duplicate(Size, $ ),
    try_update_loop(T,NRows,Scan+1,Col+Size,Row,Point,PointXY,Tab++Acc);

try_update_loop([208,X|T], NRows, Scan, Col, Row, Point, PointXY, Acc) ->
    try_update_loop(T,NRows,Scan+2,Col+1,Row,Point,PointXY,[X,208]++Acc);
try_update_loop([209,X|T], NRows, Scan, Col, Row, Point, PointXY, Acc) ->
    try_update_loop(T,NRows,Scan+2,Col+1,Row,Point,PointXY,[X,209]++Acc);

try_update_loop([H|T], NRows, Scan, Col, Row, Point, PointXY, Acc) ->
    try_update_loop(T,NRows,Scan+1,Col+1,Row,Point,PointXY,[H|Acc]);

try_update_loop([], NRows, Scan, Col, Row, Point, PointXY, Acc) ->
    draw_line(lists:reverse(Acc)),
    RemainingRows = NRows - Row,
    %% draw empty lines until the end
    dotimes(fun() -> draw_line([]),
		     ?TERM:newline()
	    end,
	    RemainingRows),
    PointXY.

draw_line(L) ->
    Wth = ?TERM:width(),
    Str = trunc_line(L, Wth),
%    error_logger:info_msg("Line: ~s",[Str]),
    ?TERM:put_string(Str),
    ?TERM:erase_to_eol().

trunc_line([H],   1) -> [H];
trunc_line(_,     1) -> [$$];
trunc_line([H|T], N) -> [H|trunc_line(T, N-1)];
trunc_line([], _)    -> [].

draw_modeline(Window) when Window#window.minibuffer == true -> ok;
draw_modeline(Window) ->
    Buffer = Window#window.buffer,
    Where = modeline_where(Window, Buffer),
    Text = lists:flatten(
         io_lib:format("-U:-mx ~s (~s) ~s",
           [atom_to_list(Buffer), (edit_buf:get_mode(Buffer))#mode.name, Where])),
    ?TERM:font_reverse(),
    slang:tt_set_color(1,"mode-line","white","blue"),
    slang:smg_set_color(1),
    ?TERM:move_to(0, Window#window.y + edit_window:physical_lines(Window) - 1),
    draw_line(Text),
    ?TERM:font_normal().

modeline_where(Window, Buffer) ->
    case edit_buf:get_size(Buffer) of
        0 -> "ALL";
        BSize ->
            Start = edit_buf:mark_pos(Buffer, Window#window.start_mark),
            Percentage = trunc(Start * 100 / BSize),
            io_lib:format("~p%", [Percentage]) end.

%% Update the display_start of a window so that it presents the point
%% in the middle of the screen.
recenter_window(Window) ->
    Buf = Window#window.buffer,
    Height = edit_window:text_lines(Window),
    Pos = backward_lines(Buf, trunc(Height / 2)),
    edit_buf:move_mark(Buf, Window#window.start_mark, Pos),
    Window.

backward_lines(Buf, N) ->
    StartPos = edit_lib:beginning_of_line_pos(Buf),
    edit_buf:walk_backward(Buf, fun(X) -> back_lines(X, N, StartPos) end, StartPos).

back_lines(finish, N, Pos) -> {result, 1};
back_lines($\n, N, Pos) ->
    if N == 1 -> {result, Pos};
    true -> {more, fun(New) -> back_lines(New, N-1, Pos-1) end} end;
back_lines(_, N, Pos) -> {more, fun(New) -> back_lines(New, N, Pos-1) end}.

dotimes(Fun, 0) -> true;
dotimes(Fun, N) when integer(N), N > 0 -> Fun(), dotimes(Fun, N-1).

min(X, Y) when X < Y -> X;
min(X, Y)            -> Y.
