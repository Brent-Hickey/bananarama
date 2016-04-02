%% -----------------------------------------------------------------------------
%% Copyright (C) Ngineo Limited 2015 - 2016. All rights reserved.
%% -----------------------------------------------------------------------------

%% =============================================================================
%% @doc
%% Regarding *Publish & Subscribe*, the ordering guarantees are as
%% follows:
%%
%% If _Subscriber A_ is subscribed to both *Topic 1* and *Topic 2*, and
%% _Publisher B_ first publishes an *Event 1* to *Topic 1* and then an
%% *Event 2* to *Topic 2*, then _Subscriber A_ will first receive *Event
%% 1* and then *Event 2*. This also holds if *Topic 1* and *Topic 2* are
%% identical.
%%
%% In other words, WAMP guarantees ordering of events between any given
%% _pair_ of _Publisher_ and _Subscriber_.
%% Further, if _Subscriber A_ subscribes to *Topic 1*, the "SUBSCRIBED"
%% message will be sent by the _Broker_ to _Subscriber A_ before any
%% "EVENT" message for *Topic 1*.
%%
%% There is no guarantee regarding the order of return for multiple
%% subsequent subscribe requests.  A subscribe request might require the
%% _Broker_ to do a time-consuming lookup in some database, whereas
%% another subscribe request second might be permissible immediately.
%% @end
%% =============================================================================
-module(juno_broker).
-include_lib("wamp/include/wamp.hrl").


%% API
-export([handle_message/2]).




%% =============================================================================
%% API
%% =============================================================================


%% -----------------------------------------------------------------------------
%% @doc
%% Handles a wamp message. This function is called by the juno_router module.
%% The message might be handled synchronously (it is performed by the calling
%% process i.e. the transport handler) or asynchronously (by sending the
%% message to the broker worker pool).
%% @end
%% -----------------------------------------------------------------------------
-spec handle_message(M :: message(), Ctxt :: map()) -> ok.
handle_message(#subscribe{} = M, Ctxt) ->
    ReqId = M#subscribe.request_id,
    Opts = M#subscribe.options,
    Topic = M#subscribe.topic_uri,
    {ok, SubsId} = juno_pubsub:subscribe(Topic, Opts, Ctxt),
    Reply = wamp_message:subscribed(ReqId, SubsId),
    juno:send(Reply, Ctxt),
    ok;

handle_message(#unsubscribe{} = M, Ctxt) ->
    ReqId = M#unsubscribe.request_id,
    SubsId = M#unsubscribe.subscription_id,
    Reply = case juno_pubsub:unsubscribe(SubsId, Ctxt) of
        ok ->
            wamp_message:unsubscribed(ReqId);
        {error, no_such_subscription} ->
            juno_error:error(
                ?UNSUBSCRIBE, ReqId, #{}, ?WAMP_ERROR_NO_SUCH_SUBSCRIPTION
            )
    end,
    juno:send(Reply, Ctxt),
    ok;

handle_message(#publish{} = M, Ctxt) ->
    %% (RFC) Asynchronously notifies all subscribers of the published event.
    %% Note that the _Publisher_ of an event will never receive the
    %% published event even if the _Publisher_ is also a _Subscriber_ of the
    %% topic published to.
    ReqId = M#publish.request_id,
    Opts = M#publish.options,
    TopicUri = M#publish.topic_uri,
    Args = M#publish.arguments,
    Payload = M#publish.payload,
    Acknowledge = maps:get(<<"acknowledge">>, Opts, false),
    %% (RFC) By default, publications are unacknowledged, and the _Broker_ will
    %% not respond, whether the publication was successful indeed or not.
    %% This behavior can be changed with the option
    %% "PUBLISH.Options.acknowledge|bool"
    case juno_pubsub:publish(TopicUri, Opts, Args, Payload, Ctxt) of
        {ok, PubId} when Acknowledge == true ->
            Reply = wamp_message:published(ReqId, PubId),
            juno:send(Reply, Ctxt),
            %% TODO publish metaevent
            ok;
        {ok, _} ->
            %% TODO publish metaevent
            ok;
        {error, Reason} when Acknowledge == true->
            %% REVIEW use the right error uri
            Reply = juno_error:error(
                ?PUBLISH, ReqId, juno:error_dict(Reason), ?WAMP_ERROR_CANCELED
            ),
            juno:send(Reply, Ctxt),
            %% TODO publish metaevent
            ok;
        {error, _} ->
            %% TODO publish metaevent
            ok
    end.