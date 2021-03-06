%
% Copyright (c) 2016 Petr Gotthard <petr.gotthard@centrum.cz>
% All rights reserved.
% Distributed under the terms of the MIT License. See the LICENSE file.
%
-module(lorawan_application_handler).

-export([init/0, handle_join/3, handle_rx/5]).
-export([store_frame/2, send_stored_frames/2]).

-define(MAX_DELAY, 250). % milliseconds

-include_lib("lorawan_server_api/include/lorawan_application.hrl").

init() ->
    {ok, Modules} = application:get_env(lorawan_server, plugins),
    do_init(Modules, []).

do_init([], Acc) -> {ok, Acc};
do_init([Application|Rest], Acc) ->
    case invoke_init(Application) of
        ok -> do_init(Rest, Acc);
        {ok, Handlers} -> do_init(Rest, Acc++Handlers);
        Else -> Else
    end.

invoke_init({App, {AppName, Module}}) ->
    {ok, _Started} = application:ensure_all_started(AppName),
    apply(Module, init, [App]);
invoke_init({App, Module}) when is_atom(Module) ->
    apply(Module, init, [App]).

handle_join(DevAddr, App, AppArgs) ->
    invoke_handler(handle_join, App, [DevAddr, App, AppArgs]).

handle_rx(DevAddr, App, AppArgs, RxData, RxQ) ->
    invoke_handler(handle_rx, App, [DevAddr, App, AppArgs, RxData, RxQ]).

invoke_handler(Fun, App, Params) ->
    {ok, Modules} = application:get_env(lorawan_server, plugins),
    case proplists:get_value(App, Modules) of
        undefined ->
            {error, {unknown_app, App}};
        {_, Module} ->
            invoke_handler2(Module, Fun, Params);
        Module ->
            invoke_handler2(Module, Fun, Params)
    end.

invoke_handler2(Module, Fun, Params) ->
    case erlang:function_exported(Module, Fun, length(Params)) of
        true ->
            apply(Module, Fun, Params);
        false ->
            lager:warning("function ~w:~w/~w not exported", [Module, Fun, length(Params)]),
            ok
    end.

store_frame(DevAddr, TxData) ->
    mnesia:transaction(fun() ->
        mnesia:write(txframes, #txframe{frid= <<(erlang:system_time()):64>>,
            datetime=calendar:universal_time(), devaddr=DevAddr, txdata=TxData}, write)
    end).

send_stored_frames(DevAddr, DefPort) ->
    case mnesia:dirty_select(txframes, [{#txframe{devaddr=DevAddr, _='_'}, [], ['$_']}]) of
        [] ->
            mnesia:subscribe({table, txframes, simple}),
            receive
                % the record name returned is 'txframes' regardless any record_name settings
                {mnesia_table_event, {write, TxFrame, _ActivityId}} when element(#txframe.devaddr, TxFrame) == DevAddr ->
                    transmit_and_delete(DefPort, setelement(1, TxFrame, txframe), false)
                after ?MAX_DELAY ->
                    ok
            end;
        [TheOnly] ->
            transmit_and_delete(DefPort, TheOnly, false);
        [First|_Tail] ->
            transmit_and_delete(DefPort, First, true)
    end.

transmit_and_delete(DefPort, TxFrame, Pending) ->
    mnesia:dirty_delete(txframes, TxFrame#txframe.frid),
    TxData = TxFrame#txframe.txdata,
    % raw websocket does not define port
    OutPort = if
        TxData#txdata.port == undefined -> DefPort;
        true -> TxData#txdata.port
    end,
    % add the pending flag
    OutPending = TxData#txdata.pending or Pending,
    {send, TxData#txdata{port=OutPort, pending=OutPending}}.

% end of file
