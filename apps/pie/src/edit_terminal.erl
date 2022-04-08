-module(edit_terminal).
-author('Luke Gorrie').
-include_lib("eslang/include/slang.hrl").
-include_lib("pie/include/edit.hrl").
-compile(export_all).

setup() ->
    slang:tt_get_terminfo(),
    slang:kp_init(),
    slang:init_tty(7, 1, 1),
    slang:set_abort_signal(null),
    slang:smg_init_smg (),
    slang:smg_normal_video(),
    slang:setvar(newline_behaviour, ?NEWLINE_MOVES),
    refresh().

selection(XX,YY,X,Y) -> slang:tt_set_color(2,"ml","white","blue"), slang:smg_set_color_in_region(2,XX,YY,X,Y).
teardown() -> slang:smg_reset_smg(), slang:reset_tty(), ok.
newline() -> put_char($\n).
put_char(C) -> slang:smg_write_char(C).
put_string(S) -> slang:smg_write_string(S).
format(Fmt, Args) -> slang:smg_printf(Fmt, Args).
erase_to_eol() -> slang:smg_erase_eol().
move_to(X, Y) -> slang:smg_gotorc(Y, X).
refresh() -> slang:smg_refresh().
invalidate() -> slang:smg_touch_screen().
width() -> slang:getvar(screen_cols).
height() -> slang:getvar(screen_rows).
read() -> case slang:getkey() of ?ESC -> read() bor 2#10000000; N -> N end.
font_reverse() -> slang:smg_reverse_video().
font_normal() -> slang:smg_normal_video().
