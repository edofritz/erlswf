-module(swfutils).
-export([
	dumpswf/1,
	dumpswftags/1,
	filedumpswf/2,
	dumptags/2,
	dumpsecuritycheck/1,
	silentsecuritycheck/1,
	filtertags/2,
	savetofile/3,
	tagencode/2,
	abcdata/1,
	actiondata/1,
	abc2oplist/1,
	actions2oplist/1]).

-include("swf.hrl").
-include("swfabc.hrl").

%%
%% utils
%%

dumpswf({swf, Header, Tags}) ->
	io:format("~n-----------------------------------~n", []),
	io:format("** header: ~p~n", [Header]),
	dumpswftags(Tags).

dumpswftags([]) -> done;
dumpswftags([{tag, Code, Name, Pos, _Raw, Contents}|Rest]) ->
	io:format("** <~8.10.0B> [~3.10.0B] ~p : ~p~n", [Pos, Code, Name, Contents]),
	dumpswftags(Rest);
dumpswftags([{rawtag, Code, Name, Pos, _Raw, _}|Rest]) ->
	io:format("** <~8.10.0B> [~3.10.0B] ~p : (not decoded)~n", [Pos, Code, Name]),
	dumpswftags(Rest).



filedumpswf(#swf{header=Header, tags=Tags}, Prefix) ->
	%% dump header
	savetofile("~s-header.erl", [Prefix], list_to_binary(io_lib:format("~p~n", [Header]))),
	
	%% dump tags
	lists:foldl(fun(Tag, Acc) ->
		lists:foreach(fun({Postfix, _MimeType, B}) ->
			savetofile("~s-tag~5.10.0B~s", [Prefix, Acc, Postfix], B)
			end, swfformat:tagformat(Tag)),
		Acc + 1 end, 1, Tags).


dumptags(#swf{tags=RawTags}, Tagnames) ->
	dumpswftags([swf:tagdecode(Tag) || Tag <- filtertags(Tagnames, RawTags)]).



getactions(doAction, TagContents) ->
	{value, {actions, Actions}} = lists:keysearch(actions, 1, TagContents),
	Actions;
getactions(doInitAction, TC) ->
	getactions(doAction, TC).

checkactions([]) -> ok;
checkactions(Actions) -> %% >= 1 element
	[{_, LastActionArgs}|_] = lists:reverse(Actions), %% assumption: min 1 element available
	{value, {pos, LastActionPos}} = lists:keysearch(pos, 1, LastActionArgs),
	
	case lists:keysearch(unknownAction, 1, Actions) of
		false -> ok;
		{value, X} -> throw(X)
	end,
	
	Branches = lists:filter(fun({Op, _Args}) -> lists:member(Op, ['jump', 'if']) end, Actions),
	lists:foreach(fun({_, Args}) ->
		{value, {branchOffset, BO}} = lists:keysearch(branchOffset, 1, Args),
		{value, {pos, Pos}} = lists:keysearch(pos, 1, Args),
		Report = fun(Cond) ->
			case Cond of
				true -> throw({branchOOB, Pos});
				false -> ok
			end
		end,
		Report(BO + Pos < 0),
		Report(BO + Pos > LastActionPos) 
		end, Branches),
	ok.
	
has_invalid_actions_t(Tags) ->
	ActiveTags = filtertags(['doInitAction', 'doAction'], Tags),

	lists:foreach(fun({tag, _Code, Name, _Pos, _Raw, Contents}) ->
		Actions = getactions(Name, Contents),
		checkactions(Actions)
		end, ActiveTags),
	ok.

has_invalid_actions(Tags) ->
	try has_invalid_actions_t(Tags) of
		_ -> false
	catch
		throw:X -> {true, X}
	end.

dumpsecuritycheck(#swf{tags=Tags}) ->
	T1 = case lists:keysearch(unknownTag, 3, Tags) of
		false -> ok;
		{value, X} -> io:format("	contains unknown tag: ~p~n", [X])
	end,
	
	T2 = case has_invalid_actions(Tags) of
		false -> ok;
		{true, Why} -> io:format("	contains invalid action: ~p~n", [Why])
	end,
	
	(T1 =:= T2) =:= ok.

silentsecuritycheck(#swf{tags=Tags}) ->
	case lists:keysearch(unknownTag, 3, Tags) of
		false -> ok;
		{value, X} -> throw({not_ok, X})
	end,

	case has_invalid_actions(Tags) of
		false -> ok;
		{true, Why} -> throw({not_ok, Why})
	end,

	ok.

%%
%% helpers
%%
filtertags(Names, Tags) ->
	lists:filter(fun(#tag{name=Name}) -> lists:member(Name, Names) end, Tags).


savetofile(Fmt, Args, Data) ->
	Outfilename = lists:flatten(io_lib:format(Fmt, Args)),
	io:format("saving ~p~n", [Outfilename]),
	file:write_file(Outfilename, Data).

%% encode tag
tagencode(Code, B) ->
	BSize = size(B),
	TagAndLength = case BSize >= 16#3f of
		true ->
			<<A, X>> = <<Code:10, 16#3f:6>>,
			<<X, A, BSize:32/signed-integer-little>>;
		false ->
			<<A, X>> = <<Code:10, BSize:6>>,
			<<X, A>>
	end,
	<<TagAndLength/binary, B/binary>>.


abcdata(#swf{tags=RawTags}) ->
	AbcTags = [swf:tagdecode(Tag) || Tag <- filtertags(['doABC', 'doABC1'], RawTags)],
	lists:map(fun(#tag{contents=Contents}) ->
		{value, {data, Abc}} = lists:keysearch(data, 1, Contents),
		Abc
	end, AbcTags).

actiondata(#swf{tags=RawTags}) ->
	ActionTags = [swf:tagdecode(Tag) || Tag <- filtertags(['doAction', 'doInitAction', 'defineButton', 'defineButton2'], RawTags)],
	lists:map(fun(#tag{contents=Contents}) ->
		case lists:keysearch(actions, 1, Contents) of
			{value, {_, Actions}} -> Actions;
			false -> case lists:keysearch(buttoncondaction, 1, Contents) of
				{value, {_, Actions, _}} -> Actions;
				false -> []
			end
		end
	end, ActionTags).


%% get op-list-list for n-gram analysis
%% returns [[atom(),...],...]
abc2oplist(#abcfile{method_body=MB}) ->
	lists:map(fun(#method_body{code=Code}) ->
		[C#instr.name || C <- Code]
	end, MB).

actions2oplist(Actions) ->
	lists:map(fun({Name, _}) -> Name end, Actions).

