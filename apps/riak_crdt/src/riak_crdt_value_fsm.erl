%%%-------------------------------------------------------------------
%%% @author Russell Brown <russelldb@basho.com>
%%% @copyright (C) 2011, Russell Brown
%%% @doc
%%% co-ordinator for a CRDT update operation
%%% @end
%%% Created : 22 Nov 2011 by Russell Brown <russelldb@basho.com>
%%%-------------------------------------------------------------------
-module(riak_crdt_value_fsm).

-behaviour(gen_fsm).

%% API
-export([start_link/3]).

%% Callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3]).

%% States
-export([prepare/2, execute/2, waiting/2]).

-record(state, {req_id :: pos_integer(),
                from :: pid(),
                key :: string(),
                values :: [term()],
                preflist :: riak_core_apl:preflist2(),
                coord_pl_entry :: {integer(), atom()},
                num_r = 0 :: non_neg_integer()}).

%%%===================================================================
%%% API
%%%===================================================================
start_link(ReqID, From, Key) ->
    gen_fsm:start_link(?MODULE, [ReqID, From, Key], []).

%%%===================================================================
%%% States
%%%===================================================================

%% @doc Initialize the state data.
init([ReqID, From, Key]) ->
    SD = #state{req_id=ReqID,
                from=From,
                key=Key},
    {ok, prepare, SD, 0}.

%% @doc Prepare the update by calculating the _preference list_.
prepare(timeout, SD0=#state{key=Key}) ->
    {ok,Ring} = riak_core_ring_manager:get_my_ring(),
    DocIdx = riak_core_util:chash_key({Key, Key}),
    UpNodes = riak_core_node_watcher:nodes(riak_crdt),
    Preflist2 = riak_core_apl:get_apl_ann(DocIdx, 3, Ring, UpNodes),
    Preflist = [IndexNode || {IndexNode, _Type} <- Preflist2],
    SD = SD0#state{ preflist = Preflist},
    {next_state, execute, SD, 0}.

%% @doc Execute the write request and then go into waiting state to
%% verify it has meets consistency requirements.
execute(timeout, SD0=#state{preflist=Preflist, key=Key, req_id=ReqId}) ->
    riak_crdt_vnode:value(Preflist, Key, ReqId),
    {next_state, waiting, SD0}.

%% @doc Gather some responses, and merge them
waiting({ReqId, CRDT}, SD0=#state{from=From, num_r=NumR0}) ->
    NumR = NumR0 + 1,
    SD = SD0#state{num_r=NumR},
    if
        NumR =:= 2 ->
            From ! {ReqId, CRDT},
            {stop, normal, SD};
        true ->
            {next_state, waiting, SD}
    end.

handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.