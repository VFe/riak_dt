-module(riak_crdt_vnode).
-behaviour(riak_core_vnode).
-include_lib("riak_core/include/riak_core_vnode.hrl").
-include("riak_crdt.hrl").

-export([start_vnode/1,
         init/1,
         terminate/2,
         handle_command/3,
         is_empty/1,
         delete/1,
         handle_handoff_command/3,
         handoff_starting/2,
         handoff_cancelled/1,
         handoff_finished/2,
         handle_handoff_data/2,
         encode_handoff_item/2,
         handle_coverage/4,
         handle_exit/3]).

%% CRDT API
-export([value/2,
        update/4,
         merge/4]).
        
-record(state, {partition, data}).

-define(MASTER, riak_crdt_vnode_master).
-define(sync(PrefList, Command, Master),
        riak_core_vnode_master:sync_command(PrefList, Command, Master)).

%% API
start_vnode(I) ->
    riak_core_vnode_master:get_vnode_pid(I, ?MODULE).

value(IdxNode, Key) ->
    ?sync(IdxNode, {value, Key}, ?MASTER).

%% Call sync, at source
update(IdxNode, Key, Mod, Args) ->
    ?sync(IdxNode, {update, Key, Mod, Args}, ?MASTER).

%% Call async at replica
merge(PrefList, Key, CRDT, ReqId) ->
    riak_core_vnode_master:command(PrefList, {merge, Key, CRDT, ReqId}, {fsm, undefined, self()}, ?MASTER).

%% Vnode API
init([Partition]) ->
    {ok, #state { partition=Partition, data=orddict:new() }}.

handle_command({value, Key}, _Sender, #state{data=Data}=State) ->
    Reply = case orddict:find(Key, Data) of
                {ok, {Mod, Val}} -> Mod:value(Val);
                _ -> notfound
            end,
    {reply, Reply, State};
handle_command({update, Key, Mod,  Args}, _Sender, #state{data=Data, partition=Idx}=State) ->
    {Reply, NewState} = case orddict:find(Key, Data) of
                            {ok, {Mod, Val}} -> 
                                Updated = Mod:update(Args, {node(), Idx}, Val),
                                {{ok, {Mod, Updated}}, State#state{data=orddict:store(Key, {Mod, Updated}, Data)}};
                            {ok, {DiffMod, _}} ->
                                {{error, {crdt_type_mismatch, DiffMod}}, State};
                            _ ->
                                %% Not found, so create locally
                                Updated = Mod:update(Args, {node(), Idx}, Mod:new()),
                                {{ok, {Mod, Updated}}, State#state{data=orddict:store(Key, {Mod, Updated}, Data)}}
                        end,
    {reply, Reply, NewState};
handle_command({merge, Key, {RemoteMod, RemoteVal} = Remote, ReqId}, Sender, #state{data=Data}=State) ->
    {Reply, NewState} = case orddict:find(Key, Data) of
                            {ok, {RemoteMod, LocalVal}} ->
                                {ok, State#state{data=orddict:store(Key, {RemoteMod, RemoteMod:merge(LocalVal, RemoteVal)}, Data)}};
                            {ok, {_LocalMod, _}} ->
                                {{error, crdt_type_mismatch}, State};
                            _ ->
                                {ok, State#state{data=orddict:store(Key, Remote, Data)}}
                        end,
    riak_core_vnode:reply(Sender, {ReqId, Reply}),
    {noreply, NewState};
handle_command(Message, _Sender, State) ->
    ?PRINT({unhandled_command, Message}),
    {noreply, State}.

handle_handoff_command(?FOLD_REQ{foldfun=Fun, acc0=Acc0}, _Sender, State) ->
    Acc = dict:fold(Fun, Acc0, State#state.data),
    {reply, Acc, State}.

handoff_starting(_TargetNode, State) ->
    {true, State}.

handoff_cancelled(State) ->
    {ok, State}.

handoff_finished(_TargetNode, State) ->
    {ok, State}.

handle_handoff_data(Binary, #state{data=Data0}=State) ->
    {K, V} = binary_to_term(Binary),
    Data = orddict:store(K, V, Data0),
    {reply, ok, State#state{data=Data}}.

encode_handoff_item(Name, Value) ->
    term_to_binary({Name, Value}).

is_empty(State) ->
    case orddict:size(State#state.data) of
        0 -> {true, State};
        _ -> {false, State}
    end.

delete(State) ->
    {ok, State}.

handle_coverage(_Req, _KeySpaces, _Sender, State) ->
    {stop, not_implemented, State}.

handle_exit(_Pid, _Reason, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.