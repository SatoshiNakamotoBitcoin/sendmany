import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:grpc/grpc.dart';
import 'package:sendmany/common/connection/connection_manager/bloc.dart';
import 'package:sendmany/common/connection/lnd_rpc/lnd_rpc.dart' as grpc;
import 'package:sendmany/common/models/models.dart';

import './bloc.dart';

class SubscribeChannelEventsBloc
    extends Bloc<SubscribeChannelEventsEvent, SubscribeChannelEventsState> {
  SubscribeChannelEventsBloc() {
    _subscribeTransactions();
  }

  @override
  SubscribeChannelEventsState get initialState =>
      InitialSubscribeChannelEventsState();

  @override
  Stream<SubscribeChannelEventsState> mapEventToState(
    SubscribeChannelEventsEvent event,
  ) async* {
    // Goal here is to minimize the round trips necessary to the LND daemon
    // We reuse as much information as we can from the subscription
    if (event is _ChannelActiveEvent && state is ChannelsUpdatedState) {
      ChannelsUpdatedState currentState = state;
      try {
        var channel = currentState.channels.firstWhere(
          (Channel c) => c.channelPoint == event.channelPoint,
        );
        if (channel is EstablishedChannel) {
          yield currentState.copyWith(channel.copyWith(active: true));
        } else {
          // Normally only an established channel can turn active
          throw ArgumentError('Only established channels must be active.');
        }
      } catch (e) {
        if (e is StateError) {
          print('Channelpoint ${event.channelPoint} not found');
        }
      }
    } else if (event is _ChannelInactiveEvent &&
        state is ChannelsUpdatedState) {
      ChannelsUpdatedState currentState = state;
      try {
        var channel = currentState.channels.firstWhere(
          (Channel c) => c.channelPoint == event.channelPoint,
        );
        if (channel is EstablishedChannel) {
          yield currentState.copyWith(channel.copyWith(active: false));
        } else {
          // Normally only an established channels can turn inactive
          throw ArgumentError('Only established channels can turn inactive.');
        }
      } catch (e) {
        if (e is StateError) {
          print('Channelpoint ${event.channelPoint} not found');
        }
      }
    } else if (event is _ChannelOpenedEvent && state is ChannelsUpdatedState) {
      ChannelsUpdatedState currentState = state;
      yield currentState.copyWith(event.channel);
    } else if (event is _ChannelClosedEvent && state is ChannelsUpdatedState) {
      ChannelsUpdatedState currentState = state;
      yield currentState.copyWithout(event.closeSummary.channelPoint);
    } else {
      var responseList = await Future.wait([
        _loadPendingChannels(),
        _loadChannels(),
      ]).catchError((error) {
        print(error);
      });

      var pendingChannels = responseList[0];
      var establishedChannels = responseList[1];
      var combined = <Channel>[];

      if (pendingChannels.isNotEmpty) {
        combined.addAll(pendingChannels);
        combined.add(null);
      }
      combined.addAll(establishedChannels);

      yield ChannelsUpdatedState(
        channels: combined,
        numPending: pendingChannels.length,
      );
    }
  }

  Future<List<Channel>> _loadChannels() async {
    var client = LnConnectionDataProvider().lightningClient;
    var req = grpc.ListChannelsRequest();
    var resp = await client.listChannels(req);
    return resp.channels.map((grpc.Channel c) {
      return EstablishedChannel.fromGRPC(c);
    }).toList();
  }

  Future<List<Channel>> _loadPendingChannels() async {
    var client = LnConnectionDataProvider().lightningClient;
    var req = grpc.PendingChannelsRequest();
    var resp = await client.pendingChannels(req);
    var p = PendingChannels.fromGRPC(resp);
    return [
      ...p.pendingClosingChannels,
      ...p.pendingForceClosingChannels,
      ...p.pendingOpenChannels,
      ...p.waitingCloseChannels,
    ];
  }

  void _subscribeTransactions() {
    var client = LnConnectionDataProvider().lightningClient;

    var sub = grpc.ChannelEventSubscription();
    ResponseStream stream = client.subscribeChannelEvents(
      sub,
    );

    stream.listen((update) async {
      if (update is grpc.ChannelEventUpdate) {
        switch (update.type) {
          case grpc.ChannelEventUpdate_UpdateType.OPEN_CHANNEL:
            // called when a channel was fully established
            add(
              _ChannelOpenedEvent(
                EstablishedChannel.fromGRPC(update.openChannel),
              ),
            );
            break;
          case grpc.ChannelEventUpdate_UpdateType.CLOSED_CHANNEL:
            // called when a channel finished closing
            add(
              _ChannelClosedEvent(
                ClosedChannelSummary.fromGRPC(update.closedChannel),
              ),
            );
            break;
          case grpc.ChannelEventUpdate_UpdateType.ACTIVE_CHANNEL:
            add(
              _ChannelActiveEvent(
                ChannelPoint.fromGRPC(update.activeChannel),
              ),
            );
            break;
          case grpc.ChannelEventUpdate_UpdateType.INACTIVE_CHANNEL:
            // notification when a channel goes inactive (peer goes offline)
            // or when a channel close is initiated

            // HACK: When a remote node closes a channel we only receive
            // this channel inactive event. The BLoC will reload all channels
            // but LND will still return the closing channel as established but inactive.
            await Future.delayed(Duration(seconds: 2));

            add(
              _ChannelInactiveEvent(
                ChannelPoint.fromGRPC(update.inactiveChannel),
              ),
            );
            break;
          default:
            print('unknown update type: ${update.type}');
        }
      }
    });
  }
}

class _ChannelActiveEvent extends SubscribeChannelEventsEvent {
  final ChannelPoint channelPoint;

  _ChannelActiveEvent(this.channelPoint);

  @override
  List<Object> get props => [channelPoint.toString()];
}

class _ChannelClosedEvent extends SubscribeChannelEventsEvent {
  final ClosedChannelSummary closeSummary;

  _ChannelClosedEvent(this.closeSummary);

  @override
  List<Object> get props => null;
}

class _ChannelInactiveEvent extends SubscribeChannelEventsEvent {
  final ChannelPoint channelPoint;

  _ChannelInactiveEvent(this.channelPoint);

  @override
  List<Object> get props => [channelPoint.toString()];
}

class _ChannelOpenedEvent extends SubscribeChannelEventsEvent {
  final EstablishedChannel channel;

  _ChannelOpenedEvent(this.channel);

  @override
  List<Object> get props => null;
}
