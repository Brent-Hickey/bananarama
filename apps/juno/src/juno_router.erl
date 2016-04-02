%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% The Juno Router provides the routing logic for all interactions.
%% It delegates the actual handling of a WAMP message to either juno_dealer or juno_broker.
%%
%% The Juno Router is not a process i.e. all function calls are performed by the calling process.
%%
%% ,------.                                    ,------.
%% | Peer |                                    | Peer |
%% `--+---'                                    `--+---'
%%
%%                   TCP established
%%    |<----------------------------------------->|
%%    |                                           |
%%    |               TLS established             |
%%    |+<--------------------------------------->+|
%%    |+                                         +|
%%    |+           WebSocket established         +|
%%    |+|<------------------------------------->|+|
%%    |+|                                       |+|
%%    |+|            WAMP established           |+|
%%    |+|+<----------------------------------->+|+|
%%    |+|+                                     +|+|
%%    |+|+                                     +|+|
%%    |+|+            WAMP closed              +|+|
%%    |+|+<----------------------------------->+|+|
%%    |+|                                       |+|
%%    |+|                                       |+|
%%    |+|            WAMP established           |+|
%%    |+|+<----------------------------------->+|+|
%%    |+|+                                     +|+|
%%    |+|+                                     +|+|
%%    |+|+            WAMP closed              +|+|
%%    |+|+<----------------------------------->+|+|
%%    |+|                                       |+|
%%    |+|           WebSocket closed            |+|
%%    |+|<------------------------------------->|+|
%%    |+                                         +|
%%    |+              TLS closed                 +|
%%    |+<--------------------------------------->+|
%%    |                                           |
%%    |               TCP closed                  |
%%    |<----------------------------------------->|
%%
%% ,--+---.                                    ,--+---.
%% | Peer |                                    | Peer |
%% `------'                                    `------'
%%
%% @end
%% =============================================================================
-module(juno_router).
-behaviour(gen_server).
-include_lib("wamp/include/wamp.hrl").

-define(POOL_NAME, juno_router_pool).

-type event()                   ::  {message(), juno_context:context()}.

-record(state, {
    pool_type = permanent       ::  permanent | transient,
    event                       ::  event()
}).

%% API
-export([start_pool/0]).
-export([handle_message/2]).
%% -export([has_role/2]). ur, ctxt
%% -export([add_role/2]). uri, ctxt
%% -export([remove_role/2]). uri, ctxt
%% -export([authorise/4]). session, uri, action, ctxt
%% -export([start_realm/2]). uri, ctxt
%% -export([stop_realm/2]). uri, ctxt

%% GEN_SERVER CALLBACKS
-export([init/1]).
-export([handle_info/2]).
-export([terminate/2]).
-export([code_change/3]).
-export([handle_call/3]).
-export([handle_cast/2]).



%% =============================================================================
%% API
%% =============================================================================




%% -----------------------------------------------------------------------------
%% @doc
%% @end
%% -----------------------------------------------------------------------------
-spec start_pool() -> ok.
start_pool() ->
    case do_start_pool() of
        {ok, _Child} -> ok;
        {ok, _Child, _Info} -> ok;
        {error, already_present} -> ok;
        {error, {already_started, _Child}} -> ok;
        {error, Reason} -> error(Reason)
    end.


%% -----------------------------------------------------------------------------
%% @doc
%% Handles a wamp message.
%% The message might be handled synchronously (it is performed by the calling
%% process i.e. the transport handler) or asynchronously (by sending the
%% message to the router worker pool).
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: message(), Ctxt :: map()) ->
    {ok, NewCtxt :: juno_context:context()}
    | {stop, NewCtxt :: juno_context:context()}
    | {reply, Reply :: message(), NewCtxt :: juno_context:context()}
    | {stop, Reply :: message(), NewCtxt :: juno_context:context()}.
handle_message(#hello{}, #{session_id := _} = Ctxt) ->
    %% Client already has a session!
    %% RPC:
    %% It is a protocol error to receive a second "HELLO" message during the
    %% lifetime of the session and the _Peer_ must fail the session if that
    %% happens
    Abort = wamp_message:abort(
        #{message => <<"You've sent a HELLO message more than once.">>},
        ?JUNO_SESSION_ALREADY_EXISTS
    ),
    {stop, Abort, Ctxt};

handle_message(#hello{} = M, Ctxt0) ->
    %% Client does not have a session and wants to open one
    open_session(M#hello.realm_uri, M#hello.details, Ctxt0);

handle_message(M, #{session_id := _} = Ctxt) ->
    %% Client has a session so this should be either a message
    %% for broker or dealer roles
    handle_session_message(M, Ctxt);

handle_message(_M, Ctxt) ->
    %% Client does not have a session and message is not HELLO
    Abort = wamp_message:abort(
        #{message => <<"You need to establish a session first.">>},
        ?JUNO_ERROR_NOT_IN_SESSION
    ),
    {stop, Abort, Ctxt}.



%% =============================================================================
%% API : GEN_SERVER CALLBACKS
%% =============================================================================



init([?POOL_NAME]) ->
    %% We've been called by sidejob_worker
    %% TODO publish metaevent
    {ok, #state{pool_type = permanent}};

init([Event]) ->
    %% We've been called by sidejob_supervisor
    %% We immediately timeout so that we find ourselfs in handle_info.
    %% TODO publish metaevent

    State = #state{
        pool_type = transient,
        event = Event
    },
    {ok, State, 0}.


handle_call(Event, _From, State) ->
    error_logger:error_report([
        {reason, unsupported_event},
        {event, Event}
    ]),
    {noreply, State}.


handle_cast(Event, State) ->
    try
        ok = handle_event(Event),
        {noreply, State}
    catch
        throw:abort ->
            %% TODO publish metaevent
            {noreply, State};
        _:Reason ->
            %% TODO publish metaevent
            error_logger:error_report([
                {reason, Reason},
                {stacktrace, erlang:get_stacktrace()}
            ]),
            {noreply, State}
    end.



handle_info(timeout, #state{pool_type = transient} = State) ->
    %% We've been spawned to handle this single event, so we should stop after
    ok = handle_event(State#state.event),
    {stop, normal, State};

handle_info(_Info, State) ->
    {noreply, State}.


terminate(normal, _State) ->
    ok;
terminate(shutdown, _State) ->
    ok;
terminate({shutdown, _}, _State) ->
    ok;
terminate(_Reason, _State) ->
    %% TODO publish metaevent
    ok.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.



%% =============================================================================
%% PRIVATE
%% =============================================================================


%% @private
do_start_pool() ->
    Size = juno_config:pool_size(?POOL_NAME),
    Capacity = juno_config:pool_capacity(?POOL_NAME),
    case juno_config:pool_type(?POOL_NAME) of
        permanent ->
            sidejob:new_resource(?POOL_NAME, ?MODULE, Capacity, Size);
        transient ->
            sidejob:new_resource(?POOL_NAME, sidejob_supervisor, Capacity, Size)
    end.



%% @private
open_session(RealmUri, Details, Ctxt0) ->
    try
        Session = juno_session:open(RealmUri, Details),
        SessionId = juno_session:id(Session),
        Ctxt1 = Ctxt0#{
            session_id => SessionId,
            realm_uri => RealmUri
        },
        Welcome = wamp_message:welcome(
            SessionId,
            #{
                agent => ?JUNO_VERSION_STRING,
                roles => #{
                    dealer => #{},
                    broker => #{}
                }
            }
        ),
        {reply, Welcome, Ctxt1}
    catch
        error:{not_found, RealmUri} ->
            Abort = wamp_message:abort(
                #{message => <<"Real does not exist.">>},
                ?WAMP_ERROR_NO_SUCH_REALM
            ),
            {stop, Abort, Ctxt0};
        error:{invalid_options, missing_client_role} ->
            Abort = wamp_message:abort(
                #{message => <<"Please provide at least one client role.">>},
                <<"wamp.error.missing_client_role">>
            ),
            {stop, Abort, Ctxt0}
    end.



%% @private
-spec handle_session_message(M :: message(), Ctxt :: map()) ->
    {ok, NewCtxt :: juno_context:context()}
    | {stop, NewCtxt :: juno_context:context()}
    | {reply, Reply :: message(), NewCtxt :: juno_context:context()}
    | {stop, Reply :: message(), NewCtxt :: juno_context:context()}.
handle_session_message(#goodbye{}, #{goodbye_initiated := true} = Ctxt) ->
    %% The client is replying to our goodbye() message.
    {stop, Ctxt};

handle_session_message(#goodbye{} = M, Ctxt) ->
    %% Goodbye initiated by client, we reply with goodbye().
    #{session_id := SessionId} = Ctxt,
    error_logger:info_report(
        "Session ~p closed as per client request. Reason: ~p~n",
        [SessionId, M#goodbye.reason_uri]
    ),
    Reply = wamp_message:goodbye(#{}, ?WAMP_ERROR_GOODBYE_AND_OUT),
    {stop, Reply, Ctxt};

handle_session_message(M, Ctxt0) ->
    %% Client already has a session.
    %% By default, publications are unacknowledged, and the _Broker_ will
    %% not respond, whether the publication was successful indeed or not.
    %% This behavior can be changed with the option
    %% "PUBLISH.Options.acknowledge|bool"
    Acknowledge = acknowledge_message(M),
    %% We asynchronously handle the message by sending it to the router pool
    case cast_session_message(?POOL_NAME, M, Ctxt0) of
        {ok, Ctxt1} ->
            {ok, Ctxt1};
        {error, Reason, Ctxt1} when Acknowledge == true ->
            %% TODO Maybe publish metaevent
            %% REVIEW are we using the right error uri?
            Error = juno_error:error(
                ?UNSUBSCRIBE,
                M#unsubscribe.request_id,
                juno:error_dict(Reason),
                ?WAMP_ERROR_CANCELED
            ),
            {reply, Error, Ctxt1};
        {error, Ctxt1}->
            %% TODO Maybe publish metaevent
            {ok, Ctxt1}
    end.


acknowledge_message(#publish{options = Opts}) ->
    maps:get(<<"acknowledge">>, Opts, false);
acknowledge_message(_) ->
    true.



%% =============================================================================
%% PRIVATE : GEN_SERVER
%% =============================================================================



%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% Asynchronously handles a message by either calling an existing worker or
%% spawning a new one depending on the juno_broker_pool_type type.
%% This message will be handled by the worker's (gen_server)
%% handle_info callback function.
%% @end.
%% -----------------------------------------------------------------------------
-spec cast_session_message(atom(), term(), juno_context:context()) ->
    {ok, juno_context:context()}
    | {error, overload, juno_context:context()}
    | {error, any(), juno_context:context()}.
cast_session_message(PoolName, M, Ctxt) ->
    Resp = case juno_config:pool_type(PoolName) of
        permanent ->
            %% We send a request to an existing permanent worker
            %% using sidejob_worker
            sidejob:cast(PoolName, {M, Ctxt});
        transient ->
            %% We spawn a transient worker using sidejob_supervisor
            sidejob_supervisor:start_child(
                PoolName,
                gen_server,
                start_link,
                [juno_broker, [{M, Ctxt}], []]
            )
    end,
    return(Resp, Ctxt).


%% @private
return(ok, Ctxt) ->
    {ok, Ctxt};
return(overload, Ctxt) ->
    error_logger:info_report([{reason, overload}, {pool, ?POOL_NAME}]),
    %% TODO publish metaevent
    {error, overload, Ctxt};
return({error, Reason}, Ctxt) ->
    {error, Reason, Ctxt}.


%% -----------------------------------------------------------------------------
%% @private
%% @doc
%% @end.
%% -----------------------------------------------------------------------------
-spec handle_event(event()) -> ok.
handle_event({#subscribe{} = M, Ctxt}) ->
    juno_broker:handle_message(M, Ctxt);

handle_event({#unsubscribe{} = M, Ctxt}) ->
    juno_broker:handle_message(M, Ctxt);

handle_event({#publish{} = M, Ctxt}) ->
    juno_broker:handle_message(M, Ctxt);

handle_event({#register{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

handle_event({#unregister{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

handle_event({#call{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

handle_event({#cancel{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

handle_event({#yield{} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

handle_event({#error{request_type = ?INVOCATION} = M, Ctxt}) ->
    juno_dealer:handle_message(M, Ctxt);

handle_event({_M, _Ctxt}) ->
    error(unexpected_message).