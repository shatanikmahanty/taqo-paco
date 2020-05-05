import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:taqo_event_server_protocol/src/tesp_codec.dart';
import 'package:taqo_event_server_protocol/src/tesp_message_socket.dart';
import 'package:taqo_event_server_protocol/taqo_event_server_protocol.dart';
import 'package:test/test.dart';

import 'tesp_matchers.dart';

const _stringAddEvent = 'addEvent';
const _stringPause = 'pause';
const _stringResume = 'resume';
const _stringAllData = 'allData';
const _stringWhiteListDataOnly = 'whiteListDataOnly';

void main() {
  group('TespServer - single client', () {
    int port;
    TestingEventServer server;
    Socket socket;
    TespMessageSocket<TespResponse, TespMessage> tespSocket;

    setUp(() async {
      server = TestingEventServer();
      await server.serve();
      port = server.port;
      socket = await Socket.connect('127.0.0.1', port);
      tespSocket =
          TespMessageSocket(socket, timeoutMillis: Duration(milliseconds: 500));
    });

    tearDown(() async {
      await tespSocket.close();
      await server.close();
      socket.destroy();
      port = null;
      tespSocket = null;
      socket = null;
      server = null;
    });

    test('ping request', () async {
      tespSocket.add(TespRequestPing());
      await tespSocket.close();
      await expectLater(tespSocket.stream,
          emitsInOrder([equalsTespMessage(TespResponseSuccess()), emitsDone]));
    });

    test('status change', () async {
      var tespStream = tespSocket.stream.asBroadcastStream(
          onCancel: (subscription) => subscription.pause(),
          onListen: (subscription) => subscription.resume());

      expect(server.isPaused, isFalse);
      expect(server.isAllData, isTrue);
      tespSocket.add(TespRequestPause());
      await expectLater(
          tespStream,
          emits(
              equalsTespMessage(TespResponseAnswer.withPayload(_stringPause))));
      expect(server.isPaused, isTrue);
      tespSocket.add(TespRequestWhiteListDataOnly());
      await expectLater(
          tespStream,
          emits(equalsTespMessage(
              TespResponseAnswer.withPayload(_stringWhiteListDataOnly))));
      expect(server.isAllData, isFalse);
      await tespSocket.close();
      await expectLater(tespStream, emitsDone);
    });

    test('stream of requests', () async {
      var requests = [
        TespRequestAddEvent.withPayload('1'),
        TespRequestAddEvent.withPayload('2'),
        TespRequestWhiteListDataOnly(),
        TespRequestAddEvent.withPayload('3'),
        TespRequestPause(),
        TespRequestAddEvent.withPayload('4'),
        TespRequestAddEvent.withPayload('5'),
        TespRequestResume(),
        TespRequestAddEvent.withPayload('6'),
        TespRequestAllData(),
        TespRequestAddEvent.withPayload('7')
      ];
      var responses = [
        TespResponseAnswer.withPayload('${_stringAddEvent}: 1'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 2'),
        TespResponseAnswer.withPayload(_stringWhiteListDataOnly),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 3'),
        TespResponseAnswer.withPayload(_stringPause),
        TespResponsePaused(),
        TespResponsePaused(),
        TespResponseAnswer.withPayload(_stringResume),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 6'),
        TespResponseAnswer.withPayload(_stringAllData),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 7'),
      ];
      requests.forEach((element) {
        tespSocket.add(element);
      });
      await tespSocket.close();
      await expectLater(
          tespSocket.stream,
          emitsInOrder(responses.map((e) => equalsTespMessage(e)).toList() +
              [emitsDone]));
    });

    test('handle large payload', () async {
      var tespStream = tespSocket.stream.asBroadcastStream(
          onCancel: (subscription) => subscription.pause(),
          onListen: (subscription) => subscription.resume());
      // Constructing large encoded message
      // Target payload size in bytes
      final targetSize = 256 * 1024 * 1024;
      final repeatingTimes = targetSize ~/ largePayloadEncoded.length;
      final realPayloadEncodedSize =
          largePayloadEncoded.length * repeatingTimes;
      final realPayload = utf8.decode(largePayloadEncoded) * repeatingTimes;
      final encodedMessageHeader = Uint8List(TespCodec.payloadOffset);
      encodedMessageHeader[TespCodec.versionOffset] = TespCodec.protocolVersion;
      encodedMessageHeader[TespCodec.codeOffset] =
          TespMessage.tespCodeRequestAddEvent;
      var bdata = ByteData.view(encodedMessageHeader.buffer,
          TespCodec.payloadSizeOffset, TespCodec.payloadSizeLength);
      bdata.setUint32(0, realPayloadEncodedSize, Endian.big);
      socket.add(encodedMessageHeader);
      for (var i = 0; i < repeatingTimes; i++) {
        socket.add(largePayloadEncoded);
      }
      await tespSocket.close();
      await expectLater(
          tespStream,
          emits(equalsTespMessage(TespResponseAnswer.withPayload(
              '${_stringAddEvent}: $realPayload'))));
      await expectLater(tespStream, emitsDone);
    }, timeout: Timeout(Duration(seconds: 120)));

    test('error handling - wrong version', () async {
      tespSocket.add(TespRequestAddEvent.withPayload('test'));
      socket.add([0xFF, 0x01, 0x02, 0x03, 0x04]);
      tespSocket.add(TespRequestAddEvent.withPayload('will not be responded'));
      await tespSocket.close();
      await expectLater(
          tespSocket.stream,
          emitsInOrder([
            equalsTespMessage(
                TespResponseAnswer.withPayload('${_stringAddEvent}: test')),
            isA<TespResponseInvalidRequest>(),
            emitsDone
          ]));
    });

    test('error handling - wrong code', () async {
      tespSocket.add(TespRequestAddEvent.withPayload('test'));
      socket.add([0x01, 0xFF, 0x01, 0x02, 0x03]);
      tespSocket.add(TespRequestAddEvent.withPayload('will not be responded'));
      await tespSocket.close();
      await expectLater(
          tespSocket.stream,
          emitsInOrder([
            equalsTespMessage(
                TespResponseAnswer.withPayload('${_stringAddEvent}: test')),
            isA<TespResponseInvalidRequest>(),
            emitsDone
          ]));
    });

    test('error handling - bad payload', () async {
      tespSocket.add(TespRequestAddEvent.withPayload('test'));
      socket.add([0x01, 0x01, 0x00, 0x00, 0x00, 0x03, 0xE1, 0xA0, 0xC0]);
      tespSocket.add(TespRequestAddEvent.withPayload('will not be responded'));
      await tespSocket.close();
      await expectLater(
          tespSocket.stream,
          emitsInOrder([
            equalsTespMessage(
                TespResponseAnswer.withPayload('${_stringAddEvent}: test')),
            isA<TespResponseInvalidRequest>(),
            emitsDone
          ]));
    });

    test('error handling - sending response to server', () async {
      tespSocket.add(TespRequestAddEvent.withPayload('1'));
      tespSocket.add(TespResponseAnswer.withPayload(
          'will cause an exception and be ignored'));
      tespSocket.add(TespRequestAddEvent.withPayload('2'));
      await tespSocket.close();
      await expectLater(
          tespSocket.stream,
          emitsInOrder([
            equalsTespMessage(
                TespResponseAnswer.withPayload('${_stringAddEvent}: 1')),
            isA<TespResponseInvalidRequest>(),
            equalsTespMessage(
                TespResponseAnswer.withPayload('${_stringAddEvent}: 2')),
            emitsDone
          ]));
    });

    test('errors do not break the server', () async {
      tespSocket.add(TespRequestPause());
      socket.add([0xFF]);
      await expectLater(
          tespSocket.stream,
          emitsInOrder([
            equalsTespMessage(
                TespResponseAnswer.withPayload('${_stringPause}')),
            isA<TespResponseInvalidRequest>(),
            emitsDone
          ]));
      socket.destroy();
      socket = await Socket.connect('127.0.0.1', port);
      tespSocket = TespMessageSocket(socket);
      tespSocket.add(TespRequestAddEvent.withPayload('will be ignored'));
      tespSocket.add(TespRequestResume());
      tespSocket.add(TespRequestAddEvent.withPayload('OK'));
      await tespSocket.close();
      await expectLater(
          tespSocket.stream,
          emitsInOrder([
                TespResponsePaused(),
                TespResponseAnswer.withPayload('$_stringResume'),
                TespResponseAnswer.withPayload('${_stringAddEvent}: OK')
              ].map((e) => equalsTespMessage(e)).toList() +
              [emitsDone]));
    });

    test('client closing early do not break the server', () async {
      tespSocket.add(TespRequestAddEvent.withPayload('test1'));
      tespSocket.add(TespRequestAddEvent.withPayload('test2'));
      tespSocket.add(TespRequestAddEvent.withPayload('test3'));
      await socket.flush();
      socket.destroy();
      socket = await Socket.connect('127.0.0.1', port);
      tespSocket = TespMessageSocket(socket);
      tespSocket.add(TespRequestAddEvent.withPayload('OK'));
      await tespSocket.close();
      await expectLater(
          tespSocket.stream,
          emitsInOrder([
                TespResponseAnswer.withPayload('${_stringAddEvent}: OK')
              ].map((e) => equalsTespMessage(e)).toList() +
              [emitsDone]));
    });
  });

  group('TespServer - multiple clients', () {
    int port;
    TestingEventServer server;
    Socket socket1, socket2;
    TespMessageSocket<TespResponse, TespMessage> tespSocket1, tespSocket2;

    setUp(() async {
      server = TestingEventServer();
      await server.serve();
      port = server.port;
      socket1 = await Socket.connect('127.0.0.1', port);
      tespSocket1 = TespMessageSocket(socket1);
      socket2 = await Socket.connect('127.0.0.1', port);
      tespSocket2 = TespMessageSocket(socket2);
    });

    tearDown(() async {
      await server.close();
      await tespSocket1.close();
      await tespSocket2.close();
      socket1.destroy();
      socket2.destroy();
      port = null;
      server = null;
      tespSocket1 = null;
      tespSocket2 = null;
      socket1 = null;
      socket2 = null;
    });

    test('clients receives responses to their own requests', () async {
      var requests1 = [
        TespRequestAddEvent.withPayload('1'),
        TespRequestAddEvent.withPayload('3'),
        TespRequestAddEvent.withPayload('5'),
        TespRequestAddEvent.withPayload('7'),
        TespRequestAddEvent.withPayload('9'),
      ];
      var responses1 = [
        TespResponseAnswer.withPayload('${_stringAddEvent}: 1'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 3'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 5'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 7'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 9'),
      ];
      var requests2 = [
        TespRequestAddEvent.withPayload('2'),
        TespRequestAddEvent.withPayload('4'),
        TespRequestAddEvent.withPayload('6'),
        TespRequestAddEvent.withPayload('8'),
        TespRequestAddEvent.withPayload('10'),
      ];
      var responses2 = [
        TespResponseAnswer.withPayload('${_stringAddEvent}: 2'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 4'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 6'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 8'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 10'),
      ];

      var client1 = Future(() async {
        for (var request in requests1) {
          await Future(() => tespSocket1.add(request));
        }
      });
      var client2 = Future(() async {
        for (var request in requests2) {
          await Future(() => tespSocket2.add(request));
        }
      });

      await Future.wait([client1, client2]);
      await tespSocket1.close();
      await tespSocket2.close();

      await expectLater(
          tespSocket1.stream,
          emitsInOrder(responses1.map((e) => equalsTespMessage(e)).toList() +
              [emitsDone]));
      await expectLater(
          tespSocket2.stream,
          emitsInOrder(responses2.map((e) => equalsTespMessage(e)).toList() +
              [emitsDone]));
    });

    test('one client pause/resume the server', () async {
      var beforePauseCompleter = Completer();
      var pauseCompleter = Completer();
      var beforeResumeCompleter = Completer();
      var resumeCompleter = Completer();
      var tespStream1 = tespSocket1.stream.asBroadcastStream(
          onCancel: (subscription) => subscription.pause(),
          onListen: (subscription) => subscription.resume());
      var tespStream2 = tespSocket2.stream.asBroadcastStream(
          onCancel: (subscription) => subscription.pause(),
          onListen: (subscription) => subscription.resume());

      var client1 = Future(() async {
        await Future(
            () => tespSocket1.add(TespRequestAddEvent.withPayload('1')));
        await beforePauseCompleter.future;
        await Future(() => tespSocket1.add(TespRequestPause()));
        await expectLater(
            tespStream1,
            emitsInOrder([
              equalsTespMessage(
                  TespResponseAnswer.withPayload('${_stringAddEvent}: 1')),
              equalsTespMessage(TespResponseAnswer.withPayload('$_stringPause'))
            ]));
        pauseCompleter.complete();
        await Future(
            () => tespSocket1.add(TespRequestAddEvent.withPayload('3')));
        beforeResumeCompleter.complete();
        await resumeCompleter.future;
        await Future(
            () => tespSocket1.add(TespRequestAddEvent.withPayload('5')));
      });
      var client2 = Future(() async {
        await Future(
            () => tespSocket2.add(TespRequestAddEvent.withPayload('2')));
        beforePauseCompleter.complete();
        await pauseCompleter.future;
        await Future(
            () => tespSocket2.add(TespRequestAddEvent.withPayload('4')));
        await beforeResumeCompleter.future;
        await Future(() => tespSocket2.add(TespRequestResume()));
        await expectLater(
            tespStream2,
            emitsInOrder([
              equalsTespMessage(
                  TespResponseAnswer.withPayload('${_stringAddEvent}: 2')),
              equalsTespMessage(TespResponsePaused()),
              equalsTespMessage(
                  TespResponseAnswer.withPayload('$_stringResume'))
            ]));
        resumeCompleter.complete();
        await Future(
            () => tespSocket2.add(TespRequestAddEvent.withPayload('6')));
      });
      await Future.wait([client1, client2]);
      await tespSocket1.close();
      await tespSocket2.close();
      await expectLater(
          tespStream1,
          emitsInOrder([
            equalsTespMessage(TespResponsePaused()),
            equalsTespMessage(
                TespResponseAnswer.withPayload('${_stringAddEvent}: 5')),
            emitsDone
          ]));
      await expectLater(
          tespStream2,
          emitsInOrder([
            equalsTespMessage(
                TespResponseAnswer.withPayload('${_stringAddEvent}: 6')),
            emitsDone
          ]));
    });

    test('one client error does not affect the other', () async {
      var requests2 = [
        TespRequestAddEvent.withPayload('2'),
        TespRequestAddEvent.withPayload('4'),
        TespRequestAddEvent.withPayload('6'),
        TespRequestAddEvent.withPayload('8'),
        TespRequestAddEvent.withPayload('10'),
      ];
      var responses2 = [
        TespResponseAnswer.withPayload('${_stringAddEvent}: 2'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 4'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 6'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 8'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 10'),
      ];

      var client1 = Future(() async {
        await Future(
            () => tespSocket1.add(TespRequestAddEvent.withPayload('1')));
        await Future(
            () => tespSocket1.add(TespRequestAddEvent.withPayload('3')));
        await Future(() => socket1.add([0xFF]));
        await Future(
            () => tespSocket1.add(TespRequestAddEvent.withPayload('7')));
        await Future(
            () => tespSocket1.add(TespRequestAddEvent.withPayload('9')));
      });
      var client2 = Future(() async {
        for (var request in requests2) {
          await Future(() => tespSocket2.add(request));
        }
      });

      await Future.wait([client1, client2]);
      await tespSocket1.close();
      await tespSocket2.close();

      await expectLater(
          tespSocket1.stream,
          emitsInOrder([
            equalsTespMessage(
                TespResponseAnswer.withPayload('${_stringAddEvent}: 1')),
            equalsTespMessage(
                TespResponseAnswer.withPayload('${_stringAddEvent}: 3')),
            isA<TespResponseInvalidRequest>(),
            emitsDone
          ]));
      await expectLater(
          tespSocket2.stream,
          emitsInOrder(responses2.map((e) => equalsTespMessage(e)).toList() +
              [emitsDone]));
    });
  });

  group('TespClient', () {
    int port;
    TestingEventServer server;
    TespClient client;

    setUp(() async {
      server = TestingEventServer();
      await server.serve();
      port = server.port;
      client = TespClient('127.0.0.1', port,
          chunkTimeoutMillis: Duration(milliseconds: 500));
      await client.connect();
    });

    tearDown(() async {
      await client.close();
      await server.close();
      port = null;
      client = null;
      server = null;
    });

    test('send()', () async {
      var requests = [
        TespRequestAddEvent.withPayload('1'),
        TespRequestAddEvent.withPayload('2'),
        TespRequestWhiteListDataOnly(),
        TespRequestAddEvent.withPayload('3'),
        TespRequestPause(),
        TespRequestAddEvent.withPayload('4'),
        TespRequestAddEvent.withPayload('5'),
        TespRequestResume(),
        TespRequestAddEvent.withPayload('6'),
        TespRequestAllData(),
        TespRequestAddEvent.withPayload('7')
      ];
      var responses = [
        TespResponseAnswer.withPayload('${_stringAddEvent}: 1'),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 2'),
        TespResponseAnswer.withPayload(_stringWhiteListDataOnly),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 3'),
        TespResponseAnswer.withPayload(_stringPause),
        TespResponsePaused(),
        TespResponsePaused(),
        TespResponseAnswer.withPayload(_stringResume),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 6'),
        TespResponseAnswer.withPayload(_stringAllData),
        TespResponseAnswer.withPayload('${_stringAddEvent}: 7'),
      ];
      for (var i = 0; i < requests.length; i++) {
        expect(client.send(requests[i]),
            completion(equalsTespMessage(responses[i])));
      }
      await client.close();
    });

    //  NOTE: The following test is still failing
    test('send large payload', () async {
      // Constructing large encoded message
      // Target payload size in bytes
      final targetSize = 256 * 1024 * 1024;
      final repeatingTimes = targetSize ~/ largePayloadEncoded.length;
      final realPayloadEncodedSize =
          largePayloadEncoded.length * repeatingTimes;
      final realPayload = utf8.decode(largePayloadEncoded) * repeatingTimes;
      final largeRequest = TespRequestAddEvent.withPayload(realPayload);
      expect(
          client.send(largeRequest),
          completion(equalsTespMessage(TespResponseAnswer.withPayload(
              '${_stringAddEvent}: $realPayload'))));
      await client.close();
    }, timeout: Timeout(Duration(seconds: 120)));
  });
}

class TestingEventServer with TespRequestHandlerMixin {
  TespServer _tespServer;

  TestingEventServer() {
    _tespServer = TespServer(this, timeoutMillis: Duration(milliseconds: 500));
  }

  int get port => _tespServer.port;

  Future<void> serve() async {
    await _tespServer.serve(address: '127.0.0.1', port: 0);
  }

  Future<void> close() async {
    await _tespServer.close();
  }

  bool isAllData = true;
  bool isPaused = false;

  @override
  Future<TespResponse> addEvent(String eventPayload) async {
    if (isPaused) {
      return TespResponsePaused();
    }
    await Future.delayed(Duration(milliseconds: 200));
    return TespResponseAnswer.withPayload('${_stringAddEvent}: $eventPayload');
  }

  @override
  TespResponse allData() {
    isAllData = true;
    return TespResponseAnswer.withPayload(_stringAllData);
  }

  @override
  TespResponse pause() {
    isPaused = true;
    return TespResponseAnswer.withPayload(_stringPause);
  }

  @override
  TespResponse resume() {
    isPaused = false;
    return TespResponseAnswer.withPayload(_stringResume);
  }

  @override
  TespResponse whiteListDataOnly() {
    isAllData = false;
    return TespResponseAnswer.withPayload(_stringWhiteListDataOnly);
  }
}

// A random utf-8 sequence
final largePayloadEncoded = Uint8List.fromList([
  203,
  138,
  92,
  243,
  156,
  148,
  189,
  39,
  215,
  135,
  235,
  170,
  135,
  73,
  48,
  207,
  163,
  209,
  188,
  236,
  153,
  186,
  231,
  187,
  136,
  82,
  244,
  136,
  166,
  171,
  242,
  181,
  179,
  154,
  196,
  179,
  227,
  176,
  128,
  95,
  89,
  122,
  234,
  177,
  181,
  55,
  227,
  184,
  167,
  67,
  224,
  164,
  191,
  224,
  188,
  141,
  201,
  136,
  228,
  155,
  128,
  243,
  166,
  189,
  160,
  243,
  144,
  143,
  174,
  198,
  150,
  218,
  128,
  243,
  142,
  155,
  171,
  241,
  156,
  153,
  188,
  240,
  181,
  154,
  151,
  240,
  161,
  142,
  146,
  230,
  161,
  170,
  207,
  185,
  50,
  205,
  175,
  233,
  175,
  180,
  216,
  156,
  194,
  176,
  225,
  172,
  185,
  239,
  191,
  189,
  80,
  126,
  241,
  158,
  154,
  138,
  240,
  158,
  150,
  138,
  203,
  158,
  211,
  148,
  242,
  159,
  176,
  169,
  229,
  190,
  137,
  233,
  190,
  147,
  220,
  166,
  71,
  113,
  32,
  243,
  150,
  149,
  188,
  215,
  174,
  230,
  134,
  175,
  242,
  158,
  176,
  147,
  56,
  237,
  150,
  190,
  86,
  241,
  163,
  128,
  168,
  229,
  165,
  135,
  208,
  132,
  207,
  136,
  236,
  179,
  129,
  243,
  189,
  175,
  151,
  241,
  132,
  151,
  135,
  197,
  154,
  236,
  167,
  144,
  207,
  158,
  70,
  239,
  191,
  189,
  243,
  147,
  175,
  159,
  203,
  184,
  240,
  148,
  149,
  177,
  235,
  151,
  179,
  242,
  176,
  149,
  166,
  241,
  131,
  154,
  172,
  241,
  178,
  161,
  143,
  200,
  187,
  241,
  128,
  183,
  138,
  234,
  145,
  155,
  244,
  129,
  160,
  136,
  233,
  177,
  162,
  45,
  244,
  134,
  151,
  174,
  239,
  151,
  140,
  243,
  176,
  159,
  145,
  100,
  208,
  161,
  63,
  108,
  110,
  243,
  168,
  144,
  148,
  109,
  102,
  207,
  131,
  48,
  53,
  80,
  109,
  231,
  135,
  160,
  80,
  243,
  164,
  172,
  172,
  225,
  178,
  154,
  86,
  242,
  145,
  163,
  155,
  217,
  166,
  221,
  180,
  43,
  33,
  45,
  101,
  121,
  71,
  210,
  146,
  36,
  241,
  134,
  188,
  159,
  90,
  202,
  174,
  240,
  187,
  155,
  175,
  211,
  180,
  213,
  162,
  240,
  161,
  152,
  183,
  207,
  148,
  211,
  157,
  93,
  234,
  182,
  155,
  194,
  190,
  220,
  153,
  243,
  138,
  174,
  187,
  217,
  163,
  235,
  164,
  186,
  240,
  165,
  153,
  155,
  232,
  146,
  169,
  215,
  185,
  210,
  168,
  225,
  166,
  128,
  234,
  169,
  162,
  199,
  180,
  243,
  136,
  133,
  155,
  83,
  236,
  133,
  190,
  238,
  152,
  172,
  236,
  128,
  134,
  243,
  166,
  145,
  182,
  101,
  87,
  113,
  228,
  172,
  150,
  212,
  191,
  242,
  167,
  161,
  144,
  202,
  176,
  224,
  189,
  166,
  243,
  163,
  158,
  128,
  235,
  155,
  129,
  229,
  169,
  132,
  242,
  185,
  168,
  141,
  92,
  219,
  150,
  227,
  171,
  188,
  238,
  178,
  183,
  240,
  184,
  179,
  147,
  238,
  130,
  175,
  90,
  242,
  171,
  174,
  167,
  63,
  243,
  182,
  131,
  136,
  83,
  243,
  153,
  185,
  163,
  212,
  160,
  241,
  135,
  153,
  129,
  92,
  205,
  167,
  91,
  197,
  139,
  239,
  191,
  189,
  223,
  145,
  219,
  168,
  200,
  190,
  229,
  144,
  150,
  241,
  175,
  147,
  150,
  227,
  141,
  167,
  91,
  227,
  143,
  133,
  198,
  171,
  220,
  144,
  241,
  128,
  184,
  177,
  51,
  238,
  144,
  151,
  62,
  241,
  169,
  170,
  133,
  215,
  147,
  215,
  144,
  225,
  190,
  181,
  211,
  134,
  244,
  135,
  132,
  174,
  225,
  173,
  189,
  207,
  185,
  197,
  181,
  204,
  189,
  243,
  128,
  170,
  175,
  221,
  177,
  203,
  135,
  228,
  150,
  152,
  222,
  138,
  235,
  132,
  162,
  210,
  143,
  215,
  140,
  212,
  135,
  235,
  164,
  134,
  226,
  138,
  139,
  209,
  156,
  62,
  243,
  135,
  135,
  144,
  235,
  135,
  161,
  199,
  141,
  241,
  164,
  149,
  133,
  123,
  200,
  164,
  217,
  181,
  34,
  239,
  191,
  189,
  240,
  171,
  171,
  128,
  243,
  142,
  187,
  172,
  216,
  146,
  203,
  188,
  240,
  191,
  148,
  129,
  71,
  50,
  67,
  240,
  150,
  152,
  141,
  210,
  168,
  232,
  178,
  169,
  240,
  189,
  142,
  191,
  210,
  162,
  194,
  157,
  213,
  148,
  226,
  157,
  150,
  126,
  51,
  88,
  74,
  243,
  190,
  176,
  132,
  205,
  189,
  208,
  157,
  91,
  234,
  139,
  169,
  215,
  130,
  217,
  163,
  236,
  165,
  186,
  67,
  119,
  70,
  197,
  173,
  241,
  185,
  129,
  175,
  55,
  229,
  174,
  186,
  60,
  243,
  175,
  190,
  161,
  221,
  128,
  241,
  132,
  153,
  167,
  225,
  155,
  159,
  200,
  130,
  238,
  169,
  130,
  242,
  128,
  175,
  185,
  232,
  135,
  181,
  231,
  132,
  187,
  69,
  210,
  138,
  212,
  183,
  78,
  240,
  188,
  128,
  135,
  211,
  137,
  116,
  227,
  163,
  176,
  242,
  185,
  142,
  168,
  87,
  48,
  212,
  156,
  230,
  178,
  140,
  243,
  175,
  139,
  163,
  214,
  149,
  243,
  150,
  169,
  160,
  243,
  159,
  172,
  153,
  224,
  160,
  130,
  243,
  172,
  191,
  132,
  225,
  154,
  136,
  243,
  158,
  155,
  135,
  229,
  182,
  190,
  201,
  190,
  201,
  187,
  212,
  130,
  229,
  178,
  130,
  227,
  180,
  187,
  244,
  130,
  146,
  160,
  230,
  153,
  149,
  84,
  240,
  160,
  146,
  187,
  244,
  129,
  152,
  141,
  114,
  225,
  148,
  130,
  223,
  166,
  241,
  148,
  171,
  190,
  201,
  178,
  226,
  140,
  129,
  225,
  139,
  183,
  242,
  189,
  133,
  185,
  119,
  228,
  137,
  186,
  91,
  241,
  163,
  134,
  189,
  229,
  155,
  129,
  233,
  187,
  172,
  76,
  221,
  135,
  218,
  161,
  50,
  243,
  162,
  179,
  172,
  234,
  173,
  129,
  113,
  239,
  169,
  188,
  244,
  130,
  153,
  172,
  242,
  135,
  160,
  151,
  35,
  225,
  144,
  147,
  205,
  189,
  243,
  158,
  144,
  136,
  92,
  218,
  190,
  231,
  181,
  135,
  41,
  241,
  191,
  146,
  170,
  203,
  181,
  81,
  208,
  142,
  225,
  160,
  179,
  204,
  131,
  233,
  146,
  159,
  238,
  141,
  187,
  98,
  62,
  54,
  202,
  162,
  243,
  187,
  169,
  191,
  241,
  151,
  140,
  147,
  199,
  173,
  232,
  187,
  161,
  222,
  177,
  39,
  212,
  189,
  228,
  141,
  149,
  107,
  241,
  182,
  133,
  156,
  109,
  239,
  191,
  189,
  62,
  229,
  141,
  176,
  226,
  140,
  153,
  33,
  221,
  184,
  223,
  167,
  194,
  172,
  228,
  165,
  168,
  239,
  144,
  128,
  201,
  152,
  218,
  153,
  222,
  191,
  202,
  180,
  213,
  128,
  109,
  220,
  174,
  230,
  175,
  156,
  76,
  201,
  182,
  46,
  100,
  204,
  143,
  243,
  179,
  153,
  166,
  204,
  133,
  235,
  157,
  163,
  118,
  241,
  136,
  176,
  137,
  201,
  186,
  72,
  242,
  172,
  139,
  133,
  122,
  51,
  240,
  181,
  188,
  178,
  239,
  175,
  147,
  214,
  150,
  231,
  170,
  175,
  239,
  191,
  189,
  237,
  146,
  145,
  230,
  170,
  158,
  221,
  129,
  241,
  169,
  155,
  160,
  207,
  161,
  207,
  139,
  123,
  222,
  151,
  234,
  186,
  168,
  236,
  135,
  152,
  239,
  140,
  178,
  243,
  161,
  136,
  144,
  202,
  183,
  218,
  184,
  204,
  129,
  105,
  197,
  154,
  234,
  177,
  180,
  49,
  241,
  187,
  129,
  181,
  224,
  178,
  152,
  223,
  145,
  206,
  173,
  242,
  131,
  166,
  150,
  226,
  179,
  144,
  239,
  191,
  189,
  242,
  168,
  150,
  180,
  199,
  177,
  239,
  134,
  151,
  241,
  188,
  168,
  185,
  233,
  151,
  174,
  222,
  131,
  216,
  149,
  230,
  178,
  171,
  223,
  172,
  240,
  153,
  179,
  161,
  87,
  223,
  190,
  236,
  176,
  167,
  218,
  162,
  206,
  176,
  197,
  162,
  206,
  164,
  115,
  227,
  153,
  136,
  206,
  153,
  241,
  139,
  190,
  149,
  243,
  131,
  132,
  153,
  229,
  133,
  176,
  242,
  184,
  134,
  172,
  199,
  170,
  36,
  239,
  191,
  189,
  237,
  142,
  136,
  45,
  203,
  190,
  242,
  163,
  156,
  135,
  242,
  186,
  188,
  191,
  243,
  177,
  172,
  181,
  55,
  32,
  242,
  166,
  153,
  178,
  123,
  48,
  225,
  129,
  163,
  243,
  144,
  150,
  145,
  85,
  208,
  180,
  219,
  152,
  214,
  139,
  92,
  53,
  239,
  130,
  185,
  242,
  130,
  151,
  157,
  232,
  136,
  161,
  121,
  198,
  171,
  242,
  161,
  155,
  162,
  75,
  238,
  167,
  135,
  88,
  205,
  176,
  243,
  130,
  133,
  165,
  236,
  157,
  191,
  72,
  224,
  173,
  189,
  122,
  235,
  160,
  147,
  214,
  135,
  243,
  133,
  170,
  152,
  81,
  230,
  168,
  135,
  96,
  209,
  132,
  237,
  146,
  151,
  242,
  186,
  163,
  183,
  243,
  139,
  191,
  131,
  229,
  180,
  170,
  234,
  142,
  159,
  202,
  179,
  236,
  181,
  130,
  225,
  150,
  181,
  230,
  186,
  178,
  235,
  142,
  174,
  126,
  244,
  128,
  135,
  162,
  121,
  239,
  149,
  171,
  196,
  146,
  240,
  150,
  186,
  133,
  227,
  188,
  134,
  239,
  191,
  141,
  45,
  243,
  168,
  184,
  154,
  208,
  153,
  210,
  146,
  241,
  151,
  142,
  176,
  223,
  190,
  241,
  169,
  164,
  190,
  229,
  181,
  187,
  98,
  215,
  162,
  214,
  152,
  239,
  190,
  157,
  226,
  133,
  128,
  240,
  185,
  187,
  187,
  201,
  132,
  241,
  130,
  159,
  151,
  240,
  152,
  184,
  176,
  240,
  144,
  149,
  135,
  208,
  172,
  238,
  164,
  163,
  241,
  137,
  191,
  159,
  242,
  169,
  152,
  128,
  95,
  45,
  111,
  243,
  152,
  172,
  129,
  240,
  183,
  154,
  139,
  210,
  150,
  231,
  179,
  133,
  239,
  191,
  189,
  119,
  220,
  135,
  242,
  190,
  142,
  177,
  75,
  227,
  167,
  154,
  203,
  137,
  239,
  141,
  187,
  221,
  160,
  216,
  178,
  195,
  129,
  52,
  225,
  182,
  159,
  211,
  185,
  118,
  240,
  163,
  159,
  163,
  90,
  236,
  187,
  145,
  102,
  204,
  179,
  231,
  137,
  174,
  100,
  230,
  184,
  141,
  226,
  173,
  158,
  235,
  141,
  146,
  226,
  151,
  188,
  201,
  175,
  242,
  190,
  150,
  179,
  116,
  94,
  36,
  122,
  237,
  138,
  166,
  239,
  191,
  189,
  229,
  174,
  145,
  42,
  226,
  141,
  191,
  200,
  184,
  243,
  175,
  178,
  169,
  203,
  169,
  240,
  176,
  163,
  182,
  228,
  183,
  178,
  229,
  137,
  144,
  229,
  156,
  168,
  229,
  164,
  146,
  235,
  152,
  150,
  202,
  171,
  244,
  129,
  190,
  189,
  244,
  140,
  173,
  170,
  241,
  191,
  150,
  132,
  230,
  160,
  148,
  195,
  185,
  201,
  144,
  222,
  170,
  208,
  178,
  201,
  190,
  211,
  150,
  236,
  190,
  184,
  226,
  147,
  190,
  243,
  155,
  128,
  144,
  79,
  243,
  157,
  139,
  183,
  243,
  177,
  181,
  156,
  225,
  131,
  137,
  232,
  166,
  170,
  225,
  159,
  142,
  241,
  139,
  182,
  149,
  122,
  244,
  142,
  152,
  169,
  117,
  224,
  164,
  136,
  241,
  174,
  140,
  158,
  110,
  76,
  39,
  240,
  156,
  172,
  139,
  240,
  163,
  174,
  176,
  232,
  186,
  165,
  113,
  206,
  135,
  243,
  143,
  152,
  143,
  33,
  120,
  230,
  137,
  164,
  214,
  186,
  232,
  170,
  144,
  241,
  182,
  177,
  169,
  198,
  189,
  241,
  147,
  147,
  189,
  241,
  190,
  140,
  173,
  195,
  186,
  244,
  143,
  151,
  184,
  216,
  184,
  198,
  130,
  233,
  173,
  190,
  54,
  225,
  145,
  129,
  196,
  166,
  83,
  226,
  145,
  153,
  79,
  61,
  214,
  176,
  97,
  38,
  240,
  146,
  140,
  135,
  119,
  236,
  149,
  128,
  208,
  154,
  103,
  226,
  139,
  151,
  74,
  219,
  129,
  211,
  170,
  240,
  190,
  141,
  139,
  222,
  150,
  241,
  191,
  174,
  171,
  214,
  153,
  241,
  188,
  135,
  161,
  82,
  237,
  147,
  149,
  79,
  241,
  166,
  134,
  159,
  194,
  160,
  204,
  178,
  70,
  209,
  167,
  196,
  182,
  230,
  142,
  133,
  243,
  191,
  128,
  143,
  240,
  161,
  180,
  132,
  241,
  183,
  143,
  161,
  244,
  142,
  135,
  168,
  227,
  143,
  180,
  239,
  138,
  157,
  58,
  242,
  166,
  138,
  171,
  222,
  155,
  231,
  180,
  140,
  204,
  161,
  211,
  162,
  236,
  149,
  157,
  234,
  164,
  128,
  36,
  240,
  162,
  177,
  139,
  205,
  135,
  201,
  168,
  202,
  169,
  238,
  136,
  156,
  94,
  95,
  217,
  165,
  226,
  139,
  137,
  235,
  137,
  165,
  66,
  48,
  120,
  235,
  132,
  149,
  241,
  143,
  140,
  182,
  233,
  129,
  137,
  243,
  150,
  131,
  132,
  198,
  148,
  201,
  147,
  34,
  113,
  243,
  129,
  182,
  149,
  228,
  186,
  172,
  244,
  130,
  186,
  174,
  87,
  124,
  241,
  160,
  169,
  162,
  239,
  149,
  191,
  242,
  148,
  159,
  171,
  241,
  157,
  163,
  191,
  204,
  141,
  57,
  239,
  157,
  177,
  242,
  150,
  165,
  156,
  58,
  236,
  139,
  169,
  201,
  189,
  206,
  156,
  226,
  185,
  152,
  214,
  136,
  231,
  182,
  152,
  88,
  89,
  48,
  209,
  181,
  222,
  189,
  239,
  191,
  189,
  243,
  180,
  189,
  174,
  240,
  157,
  171,
  167,
  200,
  177,
  241,
  167,
  166,
  143,
  239,
  191,
  189,
  92,
  224,
  177,
  146,
  230,
  171,
  164,
  241,
  175,
  157,
  162,
  98,
  235,
  144,
  186,
  105,
  216,
  135,
  222,
  183,
  125,
  240,
  179,
  168,
  159,
  242,
  172,
  159,
  144,
  229,
  150,
  177,
  220,
  176,
  113,
  86,
  235,
  140,
  177,
  214,
  131,
  119,
  227,
  177,
  145,
  43,
  203,
  136,
  243,
  146,
  185,
  182,
  54,
  229,
  161,
  179,
  230,
  189,
  136,
  240,
  191,
  187,
  148,
  78,
  205,
  181,
  232,
  188,
  188,
  243,
  187,
  165,
  184,
  241,
  175,
  179,
  172,
  224,
  160,
  165,
  58,
  113,
  114,
  212,
  129,
  243,
  184,
  151,
  157,
  236,
  185,
  178,
  230,
  139,
  174,
  241,
  190,
  132,
  187,
  100,
  75,
  242,
  171,
  159,
  136,
  242,
  172,
  156,
  173,
  197,
  154,
  38,
  240,
  191,
  130,
  172,
  223,
  160,
  34,
  198,
  141,
  195,
  155,
  239,
  181,
  146,
  244,
  133,
  167,
  166,
  200,
  150,
  236,
  159,
  160,
  215,
  169,
  243,
  174,
  138,
  132,
  227,
  172,
  169,
  89,
  226,
  190,
  162,
  211,
  168,
  229,
  141,
  175,
  242,
  162,
  159,
  166,
  236,
  143,
  144,
  217,
  173,
  240,
  159,
  174,
  139,
  242,
  172,
  144,
  182,
  228,
  158,
  152,
  243,
  168,
  175,
  139,
  65,
  242,
  152,
  129,
  178,
  235,
  153,
  175,
  106,
  83,
  243,
  169,
  146,
  189,
  222,
  176,
  221,
  157,
  212,
  151,
  241,
  144,
  137,
  186,
  239,
  191,
  189,
  243,
  168,
  152,
  179,
  75,
  118,
  195,
  153,
  226,
  157,
  144,
  221,
  174,
  231,
  164,
  160,
  203,
  168,
  198,
  163,
  231,
  181,
  130,
  241,
  156,
  191,
  183,
  230,
  137,
  140,
  243,
  182,
  191,
  170,
  195,
  190,
  227,
  189,
  178,
  242,
  187,
  143,
  163,
  109,
  217,
  172,
  226,
  134,
  189,
  194,
  177,
  222,
  175,
  232,
  189,
  165,
  242,
  130,
  132,
  146,
  200,
  137,
  102,
  240,
  145,
  150,
  165,
  240,
  155,
  158,
  147,
  241,
  138,
  190,
  171,
  241,
  162,
  169,
  143,
  108,
  240,
  171,
  174,
  186,
  48,
  241,
  143,
  147,
  167,
  206,
  179,
  194,
  187,
  38,
  241,
  173,
  170,
  141,
  126,
  35,
  243,
  130,
  150,
  164,
  222,
  166,
  199,
  152,
  239,
  191,
  189,
  116,
  241,
  129,
  160,
  129,
  65,
  243,
  162,
  148,
  187,
  120,
  243,
  147,
  191,
  176,
  66,
  211,
  170,
  194,
  137,
  210,
  174,
  230,
  147,
  174,
  243,
  147,
  178,
  146,
  89,
  241,
  157,
  135,
  170,
  242,
  186,
  168,
  191,
  242,
  132,
  185,
  184,
  194,
  134,
  76,
  221,
  169,
  222,
  186,
  242,
  131,
  160,
  150,
  80,
  229,
  128,
  145,
  54,
  199,
  153,
  200,
  140,
  216,
  140,
  242,
  149,
  140,
  131,
  244,
  128,
  160,
  175,
  199,
  134,
  206,
  175,
  242,
  164,
  174,
  184,
  205,
  135,
  241,
  163,
  176,
  133,
  241,
  188,
  159,
  164,
  242,
  175,
  138,
  166,
  44,
  203,
  180,
  228,
  182,
  143,
  79,
  240,
  167,
  136,
  156,
  207,
  158,
  222,
  171,
  75,
  56,
  242,
  188,
  173,
  191,
  232,
  173,
  180,
  240,
  146,
  153,
  181,
  214,
  189,
  232,
  184,
  184,
  226,
  143,
  183,
  232,
  176,
  191,
  232,
  151,
  152,
  241,
  133,
  170,
  160,
  208,
  171,
  217,
  167,
  67,
  55,
  243,
  157,
  154,
  190,
  91,
  117,
  230,
  169,
  136,
  232,
  146,
  145,
  241,
  141,
  190,
  177,
  227,
  148,
  175,
  64,
  242,
  143,
  190,
  158,
  243,
  156,
  156,
  169,
  242,
  169,
  191,
  190,
  105,
  220,
  155,
  214,
  187,
  96,
  238,
  164,
  172,
  244,
  131,
  190,
  170,
  202,
  158,
  241,
  184,
  140,
  144,
  106,
  205,
  190,
  225,
  173,
  142,
  241,
  175,
  186,
  169,
  241,
  158,
  177,
  139,
  242,
  176,
  149,
  191,
  196,
  159,
  241,
  151,
  157,
  168,
  61,
  72,
  210,
  153,
  236,
  169,
  168,
  242,
  160,
  179,
  142,
  215,
  176,
  243,
  183,
  179,
  164,
  239,
  164,
  172,
  243,
  173,
  138,
  135,
  243,
  134,
  165,
  181,
  241,
  176,
  150,
  171,
  243,
  150,
  167,
  187,
  38,
  215,
  129,
  240,
  146,
  161,
  130,
  201,
  142,
  80,
  215,
  139,
  118,
  242,
  175,
  182,
  138,
  221,
  130,
  115,
  78,
  118,
  199,
  141,
  212,
  156,
  242,
  140,
  160,
  157,
  244,
  138,
  165,
  154,
  234,
  137,
  154,
  242,
  147,
  166,
  165,
  244,
  134,
  188,
  136,
  243,
  184,
  143,
  129,
  240,
  145,
  152,
  165,
  217,
  176,
  230,
  182,
  172,
  241,
  191,
  171,
  178,
  242,
  135,
  159,
  140,
  234,
  159,
  153,
  200,
  170,
  241,
  158,
  145,
  174,
  118,
  243,
  138,
  167,
  175,
  211,
  153,
  230,
  149,
  143,
  235,
  154,
  168,
  229,
  134,
  137,
  242,
  172,
  161,
  137,
  232,
  176,
  149,
  87,
  219,
  173,
  223,
  130,
  242,
  169,
  129,
  131,
  62,
  60,
  225,
  158,
  178,
  241,
  140,
  151,
  142,
  225,
  138,
  181,
  200,
  157,
  201,
  185,
  236,
  134,
  147,
  95,
  48,
  240,
  178,
  154,
  142,
  214,
  136,
  237,
  133,
  166,
  50,
  105,
  243,
  139,
  133,
  165,
  56,
  202,
  154,
  208,
  168,
  204,
  147,
  242,
  182,
  141,
  165,
  56,
  118,
  195,
  168,
  241,
  147,
  140,
  184,
  230,
  190,
  171,
  205,
  168,
  66
]);
