%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at http://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ.
%%
%% The Initial Developer of the Original Code is GoPivotal, Inc.
%% Copyright (c) 2007-2014 GoPivotal, Inc.  All rights reserved.
%%

-module(worker_pool_worker).

-behaviour(gen_server2).

-export([start_link/1, next_job_from/2, submit/2, submit_async/2, run/1]).

-export([set_maximum_since_use/2]).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3, prioritise_cast/3]).

%%----------------------------------------------------------------------------

-ifdef(use_specs).

-type(mfargs() :: {atom(), atom(), [any()]}).

-spec(start_link/1 :: (any()) -> {'ok', pid()} | {'error', any()}).
-spec(next_job_from/2 :: (pid(), pid()) -> 'ok').
-spec(submit/2 :: (pid(), fun (() -> A) | mfargs()) -> A).
-spec(submit_async/2 :: (pid(), fun (() -> any()) | mfargs()) -> 'ok').
-spec(run/1 :: (fun (() -> A)) -> A; (mfargs()) -> any()).
-spec(set_maximum_since_use/2 :: (pid(), non_neg_integer()) -> 'ok').

-endif.

%%----------------------------------------------------------------------------

-define(HIBERNATE_AFTER_MIN, 1000).
-define(DESIRED_HIBERNATE, 10000).

-record(state, {id, next}).

%%----------------------------------------------------------------------------

start_link(WId) ->
    gen_server2:start_link(?MODULE, [WId], [{timeout, infinity}]).

next_job_from(Pid, CPid) ->
    gen_server2:cast(Pid, {next_job_from, CPid}).

submit(Pid, Fun) ->
    gen_server2:call(Pid, {submit, Fun, self()}, infinity).

submit_async(Pid, Fun) ->
    gen_server2:cast(Pid, {submit_async, Fun}).

set_maximum_since_use(Pid, Age) ->
    gen_server2:cast(Pid, {set_maximum_since_use, Age}).

run({M, F, A}) ->
    apply(M, F, A);
run(Fun) ->
    Fun().

%%----------------------------------------------------------------------------

init([WId]) ->
    ok = file_handle_cache:register_callback(?MODULE, set_maximum_since_use,
                                             [self()]),
    ok = worker_pool:idle(WId),
    put(worker_pool_worker, true),
    {ok, #state{id = WId}, hibernate,
     {backoff, ?HIBERNATE_AFTER_MIN, ?HIBERNATE_AFTER_MIN, ?DESIRED_HIBERNATE}}.

prioritise_cast({set_maximum_since_use, _Age}, _Len, _State) -> 8;
prioritise_cast({next_job_from, _CPid},        _Len, _State) -> 7;
prioritise_cast(_Msg,                          _Len, _State) -> 0.

handle_call({submit, Fun, CPid}, From, State = #state{next = undefined}) ->
    {noreply, State#state{next = {job, CPid, From, Fun}}, hibernate};

handle_call({submit, Fun, CPid}, From, State = #state{next = {from, CPid, MRef},
                                                      id   = WId}) ->
    erlang:demonitor(MRef),
    gen_server2:reply(From, run(Fun)),
    ok = worker_pool:idle(WId),
    {noreply, State#state{next = undefined}, hibernate};

handle_call(Msg, _From, State) ->
    {stop, {unexpected_call, Msg}, State}.

handle_cast({next_job_from, CPid}, State = #state{next = undefined}) ->
    MRef = erlang:monitor(process, CPid),
    {noreply, State#state{next = {from, CPid, MRef}}, hibernate};

handle_cast({next_job_from, CPid}, State = #state{next = {job, CPid, From, Fun},
                                                  id   = WId}) ->
    gen_server2:reply(From, run(Fun)),
    ok = worker_pool:idle(WId),
    {noreply, State#state{next = undefined}, hibernate};

handle_cast({submit_async, Fun}, State = #state{id = WId}) ->
    run(Fun),
    ok = worker_pool:idle(WId),
    {noreply, State, hibernate};

handle_cast({set_maximum_since_use, Age}, State) ->
    ok = file_handle_cache:set_maximum_since_use(Age),
    {noreply, State, hibernate};

handle_cast(Msg, State) ->
    {stop, {unexpected_cast, Msg}, State}.

handle_info({'DOWN', MRef, process, CPid, _Reason},
            State = #state{id            = WId,
                           next = {from, CPid, MRef}}) ->
    ok = worker_pool:idle(WId),
    {noreply, State#state{next = undefined}};

handle_info({'DOWN', _MRef, process, _Pid, _Reason}, State) ->
    {noreply, State};

handle_info(Msg, State) ->
    {stop, {unexpected_info, Msg}, State}.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

terminate(_Reason, State) ->
    State.
