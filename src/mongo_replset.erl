%% Get connection to appropriate server in a replica set
-module (mongo_replset).

-export_type ([replset/0, rs_connection/0]).
-export ([connect/1, primary/1, secondary_ok/1, close/1, is_closed/1]). % API

-type maybe(A) :: {A} | {}.
-type err_or(A) :: {ok, A} | {error, reason()}.
-type reason() :: any().

% -spec find (fun ((A) -> boolean()), [A]) -> maybe(A).
% return first element in list that satisfies predicate
% find (Pred, []) -> {};
% find (Pred, [A | Tail]) -> case Pred (A) of true -> {A}; false -> find (Pred, Tail) end.

-spec until_success ([A], fun ((A) -> B)) -> B. % EIO, fun EIO
% Apply fun on each element until one doesn't fail. Fail if all fail or list is empty
until_success ([], _Fun) -> throw ([]);
until_success ([A | Tail], Fun) -> try Fun (A)
	catch Reason -> try until_success (Tail, Fun)
		catch Reasons -> throw ([Reason | Reasons]) end end.

-spec rotate (integer(), [A]) -> [A].
% Move first N element of list to back of list
rotate (N, List) ->
	{Front, Back} = lists:split (N, List),
	Back ++ Front.

-type host() :: mongo_connect:host().
-type connection() :: mongo_connect:connection().

-type replset() :: {rs_name(), [host()]}.
% Identify replset. Hosts is just seed list, not necessarily all hosts in replica set
-type rs_name() :: bson:utf8().

-spec connect (replset()) -> rs_connection(). % IO
% Create new cache of connections to replica set members starting with seed members. No connection attempted until primary or secondary_ok called.
connect ({ReplName, Hosts}) ->
	Dict = dict:from_list (lists:map (fun (Host) -> {mongo_connect:host_port (Host), {}} end, Hosts)),
	{rs_connection, ReplName, mvar:new (Dict)}.

-opaque rs_connection() :: {rs_connection, rs_name(), mvar:mvar(connections())}.
% Maintains set of connections to some if not all of the replica set members
% Type not opaque to mongo:connection_mode/2
-type connections() :: dict:dictionary (host(), maybe(connection())).
% All hosts listed in last member_info fetched are keys in dict. Value is {} if no attempt to connect to that host yet

-spec primary (rs_connection()) -> err_or(connection()). % IO
% Return connection to current primary in replica set
primary (ReplConn) -> try
		MemberInfo = fetch_member_info (ReplConn),
		primary_conn (2, ReplConn, MemberInfo)
	of Conn -> {ok, Conn}
	catch Reason -> {error, Reason} end.

-spec secondary_ok (rs_connection()) -> err_or(connection()). % IO
% Return connection to a current secondary in replica set or primary if none
secondary_ok (ReplConn) -> try
		{_Conn, Info} = fetch_member_info (ReplConn),
		Hosts = lists:map (fun mongo_connect:read_host/1, bson:at (hosts, Info)),
		R = random:uniform (length (Hosts)) - 1,
		secondary_ok_conn (ReplConn, rotate (R, Hosts))
	of Conn -> {ok, Conn}
	catch Reason -> {error, Reason} end.

-spec close (rs_connection()) -> ok. % IO
% Close replset connection
close ({rs_connection, _, VConns}) ->
	CloseConn = fun (_, MCon, _) -> case MCon of {Con} -> mongo_connect:close (Con); {} -> ok end end,
	mvar:with (VConns, fun (Dict) -> dict:fold (CloseConn, ok, Dict) end),
	mvar:terminate (VConns).

-spec is_closed (rs_connection()) -> boolean(). % IO
% Has replset connection been closed?
is_closed ({rs_connection, _, VConns}) -> mvar:is_terminated (VConns).

% EIO = IO that may throw error of any type

-type member_info() :: {connection(), bson:document()}.
% Result of isMaster query on a server connnection. Returned fields are: setName, ismaster, secondary, hosts, [primary]. primary only present when ismaster = false

-spec primary_conn (integer(), rs_connection(), member_info()) -> connection(). % EIO
% Return connection to primary designated in member_info. Only chase primary pointer N times.
primary_conn (0, _ReplConn, MemberInfo) -> throw ({false_primary, MemberInfo});
primary_conn (Tries, ReplConn, {Conn, Info}) -> case bson:at (ismaster, Info) of
	true -> Conn;
	false -> case bson:lookup (primary, Info) of
		{HostString} ->
			MemberInfo = connect_member (ReplConn, mongo_connect:read_host (HostString)),
			primary_conn (Tries - 1, ReplConn, MemberInfo);
		{} -> throw ({no_primary, {Conn, Info}}) end end.

-spec secondary_ok_conn (rs_connection(), [host()]) -> connection(). % EIO
% Return connection to a live secondaries in replica set, or primary if none
secondary_ok_conn (ReplConn, Hosts) -> try
		until_success (Hosts, fun (Host) ->
			{Conn, Info} = connect_member (ReplConn, Host),
			case bson:at (secondary, Info) of true -> Conn; false -> throw (not_secondary) end end)
	catch _ -> primary_conn (2, ReplConn, fetch_member_info (ReplConn)) end.

-spec fetch_member_info (rs_connection()) -> member_info(). % EIO
% Retrieve isMaster info from a current known member in replica set. Update known list of members from fetched info.
% TODO: close connections dropped from Dict
fetch_member_info (ReplConn = {rs_connection, _ReplName, VConns}) ->
	OldHosts = dict:fetch_keys (mvar:read (VConns)),
	{Conn, Info} = until_success (OldHosts, fun (Host) -> connect_member (ReplConn, Host) end),
	NewHosts = lists:map (fun mongo_connect:read_host/1, bson:at (hosts, Info)),
	mvar:modify_ (VConns, fun (Dict) ->
		MapHost = fun (Host) -> {Host, case dict:find (Host, Dict) of {ok, MConn} -> MConn; error -> {} end} end,
		dict:from_list (lists:map (MapHost, NewHosts)) end),
	{Conn, Info}.

-spec connect_member (rs_connection(), host()) -> member_info(). % EIO
% Connect to host and verify membership. Cache connection in rs_connection
connect_member ({rs_connection, ReplName, VConns}, Host) -> mvar:modify (VConns, fun (Dict) ->
	Conn = case dict:find (Host, Dict) of
		{ok, {Con}} -> Con;
		_ -> case mongo_connect:connect (Host) of
			{ok, Con} -> Con;
			{error, Reason} -> throw ({cant_connect, Reason}) end end,
	Info = try mongo_query:command ({admin, Conn}, {isMaster, 1}, true) catch _ -> 
		case mongo_connect:reconnect (Conn) of ok -> ok; {error, Reas} -> throw ({cant_connect, Reas}) end,
		mongo_query:command ({admin, Conn}, {isMaster, 1}, true) end,
	case bson:at (setName, Info) of
		ReplName -> {dict:store (Host, {Conn}, Dict), {Conn, Info}};
		_ -> mongo_connect:close (Conn), throw ({not_member, Host, Info}) end end).
