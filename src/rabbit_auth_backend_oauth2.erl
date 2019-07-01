%% The contents of this file are subject to the Mozilla Public License
%% Version 1.1 (the "License"); you may not use this file except in
%% compliance with the License. You may obtain a copy of the License
%% at https://www.mozilla.org/MPL/
%%
%% Software distributed under the License is distributed on an "AS IS"
%% basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See
%% the License for the specific language governing rights and
%% limitations under the License.
%%
%% The Original Code is RabbitMQ HTTP authentication.
%%
%% The Initial Developer of the Original Code is VMware, Inc.
%% Copyright (c) 2007-2019 Pivotal Software, Inc.  All rights reserved.
%%

-module(rabbit_auth_backend_oauth2).

-include_lib("rabbit_common/include/rabbit.hrl").

-behaviour(rabbit_authn_backend).
-behaviour(rabbit_authz_backend).

-export([description/0]).
-export([user_login_authentication/2, user_login_authorization/2,
         check_vhost_access/3, check_resource_access/4,
         check_topic_access/4, check_token/1, state_can_expire/0, update_state/2]).

-import(rabbit_data_coercion, [to_map/1]).

-ifdef(TEST).
-compile(export_all).
-endif.
%%--------------------------------------------------------------------

description() ->
    [{name, <<"UAA">>},
     {description, <<"Performs authentication and authorisation using JWT tokens and OAuth 2 scopes">>}].

%%--------------------------------------------------------------------

user_login_authentication(Username0, AuthProps0) ->
    AuthProps = to_map(AuthProps0),
    Token     = token_from_context(AuthProps),
    case check_token(Token) of
        %% avoid logging the token
        {error, _} = E  -> E;
        {refused, {error, {invalid_token, error, _Err, _Stacktrace}}} ->
          {refused, "Authentication using an OAuth 2/JWT token failed: provided token is invalid", []};
        {refused, Err} ->
          {refused, "Authentication using an OAuth 2/JWT token failed: ~p", [Err]};
        {ok, DecodedToken} ->
            Username = username_from(Username0, DecodedToken),
            Tags     = tags_from(DecodedToken),

            {ok, #auth_user{username = Username,
                            tags = Tags,
                            impl = DecodedToken}}
    end.

user_login_authorization(Username, AuthProps) ->
    case user_login_authentication(Username, AuthProps) of
        {ok, #auth_user{impl = Impl}} -> {ok, Impl};
        Else                          -> Else
    end.

check_vhost_access(#auth_user{impl = DecodedToken},
                   VHost, _AuthzData) ->
    with_decoded_token(DecodedToken,
        fun() ->
            Scopes      = get_scopes(DecodedToken),
            ScopeString = rabbit_oauth2_scope:concat_scopes(Scopes, ","),
            rabbit_log:debug("Matching virtual host '~s' against the following scopes: ~s", [VHost, ScopeString]),
            rabbit_oauth2_scope:vhost_access(VHost, Scopes)
        end).

check_resource_access(#auth_user{impl = DecodedToken},
                      Resource, Permission, _AuthzContext) ->
    with_decoded_token(DecodedToken,
        fun() ->
            Scopes = get_scopes(DecodedToken),
            rabbit_oauth2_scope:resource_access(Resource, Permission, Scopes)
        end).

check_topic_access(#auth_user{impl = DecodedToken},
                   Resource, Permission, Context) ->
    with_decoded_token(DecodedToken,
        fun() ->
            Scopes = get_scopes(DecodedToken),
            rabbit_oauth2_scope:topic_access(Resource, Permission, Context, Scopes)
        end).

state_can_expire() -> true.

update_state(AuthUser, NewToken) ->
  case check_token(NewToken) of
      %% avoid logging the token
      {error, _} = E  -> E;
      {refused, {error, {invalid_token, error, _Err, _Stacktrace}}} ->
        {refused, "Authentication using an OAuth 2/JWT token failed: provided token is invalid"};
      {refused, Err} ->
        {refused, rabbit_misc:format("Authentication using an OAuth 2/JWT token failed: ~p", [Err])};
      {ok, DecodedToken} ->
          Tags = tags_from(DecodedToken),

          {ok, AuthUser#auth_user{tags = Tags,
                                  impl = DecodedToken}}
  end.

%%--------------------------------------------------------------------

with_decoded_token(DecodedToken, Fun) ->
    case validate_token_expiry(DecodedToken) of
        ok               -> Fun();
        {error, Msg} = Err ->
            rabbit_log:error(Msg),
            Err
    end.

validate_token_expiry(#{<<"exp">> := Exp}) when is_integer(Exp) ->
    Now = os:system_time(seconds),
    case Exp =< Now of
        true  -> {error, rabbit_misc:format("Provided JWT token has expired at timestamp ~p (validated at ~p)", [Exp, Now])};
        false -> ok
    end;
validate_token_expiry(#{}) -> ok.

-spec check_token(binary()) -> {ok, map()} | {error, term()}.
check_token(Token) ->
    case uaa_jwt:decode_and_verify(Token) of
        {error, Reason} -> {refused, {error, Reason}};
        {true, Payload} -> validate_payload(Payload);
        {false, _}      -> {refused, signature_invalid}
    end.

validate_payload(#{<<"scope">> := _Scope, <<"aud">> := _Aud} = DecodedToken) ->
    ResourceServerEnv = application:get_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<>>),
    ResourceServerId = rabbit_data_coercion:to_binary(ResourceServerEnv),
    validate_payload(DecodedToken, ResourceServerId).

validate_payload(#{<<"scope">> := Scope, <<"aud">> := Aud} = DecodedToken, ResourceServerId) ->
    case check_aud(Aud, ResourceServerId) of
        ok           -> {ok, DecodedToken#{<<"scope">> => filter_scopes(Scope, ResourceServerId)}};
        {error, Err} -> {refused, {invalid_aud, Err}}
    end.

filter_scopes(Scopes, <<"">>) -> Scopes;
filter_scopes(Scopes, ResourceServerId)  ->
    PrefixPattern = <<ResourceServerId/binary, ".">>,
    matching_scopes_without_prefix(Scopes, PrefixPattern).

check_aud(_, <<>>)    -> ok;
check_aud(Aud, ResourceServerId) ->
    case Aud of
        List when is_list(List) ->
            case lists:member(ResourceServerId, Aud) of
                true  -> ok;
                false -> {error, {resource_id_not_found_in_aud, ResourceServerId, Aud}}
            end;
        _ -> {error, {badarg, {aud_is_not_a_list, Aud}}}
    end.

%%--------------------------------------------------------------------

get_scopes(#{<<"scope">> := Scope}) -> Scope.

-spec token_from_context(map()) -> binary() | undefined.
token_from_context(AuthProps) ->
    maps:get(password, AuthProps, undefined).

%% Decoded tokens look like this:
%%
%% #{<<"aud">>         => [<<"rabbitmq">>, <<"rabbit_client">>],
%%   <<"authorities">> => [<<"rabbitmq.read:*/*">>, <<"rabbitmq.write:*/*">>, <<"rabbitmq.configure:*/*">>],
%%   <<"azp">>         => <<"rabbit_client">>,
%%   <<"cid">>         => <<"rabbit_client">>,
%%   <<"client_id">>   => <<"rabbit_client">>,
%%   <<"exp">>         => 1530849387,
%%   <<"grant_type">>  => <<"client_credentials">>,
%%   <<"iat">>         => 1530806187,
%%   <<"iss">>         => <<"http://localhost:8080/uaa/oauth/token">>,
%%   <<"jti">>         => <<"df5d50a1cdcb4fa6bf32e7e03acfc74d">>,
%%   <<"rev_sig">>     => <<"2f880d5b">>,
%%   <<"scope">>       => [<<"rabbitmq.read:*/*">>, <<"rabbitmq.write:*/*">>, <<"rabbitmq.configure:*/*">>],
%%   <<"sub">>         => <<"rabbit_client">>,
%%   <<"zid">>         => <<"uaa">>}

-spec username_from(binary(), map()) -> binary() | undefined.
username_from(ClientProvidedUsername, DecodedToken) ->
    ClientId = uaa_jwt:client_id(DecodedToken, undefined),
    Sub      = uaa_jwt:sub(DecodedToken, undefined),

    rabbit_log:debug("Computing username from client's JWT token, client ID: '~s', sub: '~s'",
                     [ClientId, Sub]),

    case uaa_jwt:client_id(DecodedToken, Sub) of
        undefined ->
            case ClientProvidedUsername of
                undefined -> undefined;
                <<>>      -> undefined;
                _Other    -> ClientProvidedUsername
            end;
        Value     ->
            Value
    end.

-spec tags_from(map()) -> list(atom()).
tags_from(DecodedToken) ->
    Scopes    = maps:get(<<"scope">>, DecodedToken, []),
    TagScopes = matching_scopes_without_prefix(Scopes, <<"tag:">>),
    lists:usort(lists:map(fun rabbit_data_coercion:to_atom/1, TagScopes)).

matching_scopes_without_prefix(Scopes, PrefixPattern) ->
    PatternLength = byte_size(PrefixPattern),
    lists:filtermap(
        fun(ScopeEl) ->
            case binary:match(ScopeEl, PrefixPattern) of
                {0, PatternLength} ->
                    ElLength = byte_size(ScopeEl),
                    {true,
                     binary:part(ScopeEl,
                                 {PatternLength, ElLength - PatternLength})};
                _ -> false
            end
        end,
        Scopes).
