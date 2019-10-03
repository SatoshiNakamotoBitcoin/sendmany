import 'dart:async';
import 'package:bloc/bloc.dart';
import 'package:grpc/grpc.dart';
import 'package:torden/common/connection/connection_manager/bloc.dart';
import 'package:torden/common/connection/lnd_rpc/lnd_rpc.dart' as grpc;
import 'package:torden/common/models/transaction.dart';
import './bloc.dart';

class SubscribeTransactionsBloc
    extends Bloc<SubscribeTransactionsEvent, SubscribeTransactionsState> {
  @override
  SubscribeTransactionsState get initialState =>
      InitialSubscribeTransactionsState();

  SubscribeTransactionsBloc() {
    _subscribeTransactions();
  }

  @override
  Stream<SubscribeTransactionsState> mapEventToState(
    SubscribeTransactionsEvent event,
  ) async* {
    if (event is TransactionChangedEvent) {
      yield TransactionChangedState(event.tx);
    }
  }

  _subscribeTransactions() {
    var client = LnConnectionDataProvider().lightningClient;
    var macaroon = LnConnectionDataProvider().macaroon;

    var opts = CallOptions(metadata: {
      "macaroon": macaroon,
    });

    grpc.GetTransactionsRequest req = grpc.GetTransactionsRequest();
    ResponseStream stream = client.subscribeTransactions(
      req,
      options: opts,
    );

    stream.listen((onData) {
      TransactionModel m = TransactionModel.fromLND(onData);
      dispatch(TransactionChangedEvent(m));
    });
  }
}