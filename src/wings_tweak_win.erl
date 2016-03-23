%%
%%  wings_tweak_win.erl --
%%
%%     Tweak tools windows.
%%
%%  Copyright (c) 2016 Dan Gudmundsson
%%
%%  See the file "license.terms" for information on usage and redistribution
%%  of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%
%%

-module(wings_tweak_win).
-export([window/2,window/5]).

-export([init/1,
	 handle_call/3, handle_cast/2,
	 handle_event/2, %% handle_sync_event/3,
	 handle_info/2, code_change/3, terminate/2
	]).

-include("wings.hrl").

%%%
%%% Geometry Graph window.
%%%

window(Name, St) ->
    case wings_wm:is_window({tweak,Name}) of
	true ->
	    wings_wm:raise({tweak,Name}),
	    keep;
	false ->
	    Pos = case Name of
		      tweak_palette -> {5,150};
		      tweak_magnet -> {25,170};
		      axis_constraint -> {45,190}
		  end,
	    wings_tweak_win:window(Name, Pos, {-1,-1}, [], St),
	    keep
    end.

window(Name0, Pos0, Size, Ps, St) ->
    Name = {tweak, Name0},
    Parent = ?GET(top_frame),
    Pos = wxWindow:clientToScreen(Parent, Pos0),
    State = get_state(Name),
    Window = wx_object:start_link(?MODULE, [Parent, Pos, Size, Ps, Name, State], []),
    wings_wm:new(Name, Window, {push,change_state(Window, St)}),
    wings_frame:register_win(Window),
    keep.

%%%%%%%% Window internals %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Inside wings (process)
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

change_state(Window, St) ->
    fun(Ev) -> forward_event(Ev, Window, St) end.

forward_event(redraw, _Window, _St) -> keep;
forward_event(init_opengl, _Window, _St) -> keep;
forward_event({apply, ReturnSt, Fun}, Window, St0) ->
    %% Apply ops from window in wings process
    case ReturnSt of
	true ->
	    St = Fun(St0),
	    {replace, change_state(Window, St)};
	false ->
	    Fun(St0)
    end;
forward_event(update_palette, Window, _) ->
    wx_object:cast(Window, {update, get_state()}),
    keep;
forward_event(Ev, Window, _) ->
    wx_object:cast(Window, Ev),
    keep.

get_state() ->
    get_state(wings_wm:this()).
get_state({_,tweak_palette}) ->
    {tweak_tool(1, {false, false, false}), valid_menu_items(wings_tweak:menu())};
get_state({_,tweak_magnet}) ->
    {wings_pref:get_value(tweak_magnet),valid_menu_items(wings_tweak:tweak_magnet_menu())};
get_state({_,axis_constraint}) ->
    {none,valid_menu_items(wings_tweak:constraints_menu())}.

tweak_tool(Button, Modifiers) ->
    TweakKeys = wings_tweak:tweak_keys(),
    case orddict:find({Button,Modifiers},TweakKeys) of
	{ok,Mode} -> Mode;
	error -> none
    end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%% Window in new (frame) process %%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

-record(state, {name, shown, mode, menu, prev}).

init([Parent, Pos, Size, _Ps, Name, {Mode, Menus}]) ->
    Frame = wings_frame:make_external_win(Parent, title(Name), [{size, Size}, {pos, Pos}]),
    Panel = wxPanel:new(Frame),
    HotKeys = wings_hotkey:matching([tweak]),
    Entries0 = [wings_menu:normalize_menu_wx(Entry, HotKeys, [tweak])
		|| Entry <- lists:flatten(Menus)],
    Entries1 = wings_menu:format_hotkeys(Entries0, pretty),
    wxPanel:setFont(Panel, ?GET(system_font_wx)),
    wxWindow:setBackgroundColour(Panel, colorB(menu_color)),
    Main = wxBoxSizer:new(?wxHORIZONTAL),
    Sizer = wxBoxSizer:new(?wxVERTICAL),
    MinHSzs = wings_menu:calc_min_sizes(Entries1, Panel, 5, 5),
    Entries = wings_menu:setup_popup(Entries1, 500, Sizer, MinHSzs, Panel, false, []),
    update_lines(Menus, Entries),
    wxSizer:setMinSize(Sizer, 225, -1),
    wxSizer:addSpacer(Main, 5),
    wxSizer:add(Main, Sizer, [{proportion, 1}, {border, 5}, {flag, ?wxALL}]),
    wxSizer:addSpacer(Main, 5),
    wxPanel:setSizer(Panel, Main),
    wxSizer:fit(Main, Panel),
    wxSizer:setSizeHints(Main, Frame),
    wxWindow:show(Frame),
    {Panel, #state{name=Name, shown=Entries, mode=Mode, menu=Menus}}.

handle_event(#wx{id=Id, obj=_Obj, event=#wxMouse{type=enter_window}},
	     #state{name=Name, shown=Entries, prev=_Prev} = State) ->
    wings_status:message(Name, wings_menu:entry_msg(Id, Entries)),
    {noreply, State#state{prev=line}};
handle_event(#wx{id=Id, event=#wxMouse{}=ME},
	     #state{name=Name, shown=Entries} = State) ->
    Cmd = case wings_menu:entry_cmd(Id, Entries) of
	      {_, {Mode, _}} -> tweak_mode_cmd(Mode, ME);
	      Command -> Command
	  end,
    Do = fun(St) -> wings_tweak:command({element(2,Name),Cmd}, St) end,
    wings_wm:psend(Name, {apply, true, Do}),
    {noreply, State};
handle_event(#wx{} = Ev, State) ->
    io:format("~p:~p Got unexpected event ~p~n", [?MODULE,?LINE, Ev]),
    {noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%

handle_call(Req, _From, State) ->
    io:format("~p:~p Got unexpected call ~p~n", [?MODULE,?LINE, Req]),
    {reply, ok, State}.

handle_cast({update, {_Mode, Menus}}, #state{shown=Entries0} = State) ->
    update_lines(Menus, Entries0),
    {noreply, State};
handle_cast(_Req, State) ->
    io:format("~p:~p Got unexpected cast ~p~n", [?MODULE,?LINE, _Req]),
    {noreply, State}.

handle_info(parent_changed, State) ->
    {noreply, State};
handle_info(Msg, State) ->
    io:format("~p:~p Got unexpected info ~p~n", [?MODULE,?LINE, Msg]),
    {noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%

code_change(_From, _To, State) ->
    State.

terminate(_Reason, #state{name=Name}) ->
    io:format("terminate: ~p:~p (~p)~n",[?MODULE, Name, _Reason]),
    wings ! {external, fun(_) -> wings_wm:delete(Name) end},
    normal.

%%%%%%%%%%%%%%%%%%%%%%

update_lines([separator|Ms], Es) ->
    update_lines(Ms, Es);
update_lines([{Name,_Cmd,_,Os}|Ms], [Entry,_|Es]) ->
    %% io:format("~p ~p = ~P~n",[Name, _Cmd, Entry, 20]),
    #{label:=T1, hotkey:=T2, panel:=Panel} = wings_menu:entry_wins(Entry),
    wxStaticText:setLabel(T1, Name),
    case proplists:get_value(hotkey, Os) of
    	undefined -> wxStaticText:setLabel(T2, "");
    	String    -> wxStaticText:setLabel(T2, String)
    end,
    case proplists:get_value(crossmark, Os, false) of
	true  -> wings_menu:setup_colors(Panel, colorB(menu_hilite), colorB(menu_hilited_text));
	false -> wings_menu:setup_colors(Panel, colorB(menu_color), colorB(menu_text))
    end,
    update_lines(Ms, Es);
update_lines([], []) ->
    %% io:format("Last ~p~n", [_E]),
    ok.

title({_,tweak_palette}) ->
    ?__(1,"Tweak");
title({_,tweak_magnet}) ->
    ?__(2,"Tweak Magnet");
title({_,axis_constraint}) ->
    ?__(3,"Tweak Axis");
title(_) -> [].

%% Get valid items form the tweak menu for the palettes
valid_menu_items([separator,{_,cycle_magnet,_}|Menu]) ->
    valid_menu_items(Menu);
valid_menu_items([separator,{_,{tweak_magnet,_}},{_,{axis_constraint,_}}|Menu]) ->
    valid_menu_items(Menu);
valid_menu_items([{_,mag_adjust,_}|Menu]) ->
    valid_menu_items(Menu);
valid_menu_items([I|Menu]) ->
    case I of
	{Name,Cmd,Help,Bound} when is_function(Cmd) -> %% menu format
	    C = Cmd(1,[]), %% change fun to cmd name.. 1 is for lmb
	    [{Name,C,Help,Bound}|valid_menu_items(Menu)];
	{Name,Cmd,Help,Bound} when is_atom(Cmd) -> %% menu format
	    [{Name,Cmd,Help,Bound}|valid_menu_items(Menu)];
	{Name, Cmd, Help} when is_atom(Cmd) ->
	    [{Name,Cmd,Help,[]}|valid_menu_items(Menu)];
	separator ->
	    [separator|valid_menu_items(Menu)]
    end;
valid_menu_items([]) -> [].

tweak_mode_cmd(Mode, #wxMouse{type=Type, controlDown=Ctrl,shiftDown=Shift,altDown=Alt}) ->
    B = case Type of
	    left_up -> 1;
	    middle_up -> 2;
	    right_up -> 3
	end,
    {set_tweak_pref, Mode, B, {Ctrl, Shift, Alt}}.

colorB(Pref) when is_atom(Pref) ->
    wings_color:rgb4bv(wings_pref:get_value(Pref));
colorB(Col) -> wings_color:rgb4bv(Col).

