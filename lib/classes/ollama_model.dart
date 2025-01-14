import 'dart:convert';
import 'dart:io';
import 'dart:ui';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:http/http.dart';
import 'package:lan_scanner/lan_scanner.dart';
import 'package:maid/classes/large_language_model.dart';
import 'package:maid/static/logger.dart';
import 'package:maid_llm/maid_llm.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

class OllamaModel extends LargeLanguageModel {
  @override
  LargeLanguageModelType get type => LargeLanguageModelType.ollama;
  
  String _ip = '';

  OllamaModel({
    super.listener, 
    super.name,
    super.uri,
    super.useDefault,
    super.penalizeNewline,
    super.seed,
    super.nKeep,
    super.nPredict,
    super.topK,
    super.topP,
    super.minP,
    super.tfsZ,
    super.typicalP,
    super.temperature,
    super.penaltyLastN,
    super.penaltyRepeat,
    super.penaltyPresent,
    super.penaltyFreq,
    super.mirostat,
    super.mirostatTau,
    super.mirostatEta,
    super.nCtx,
    super.nBatch,
    super.nThread,
    String ip = '',
  }) {
    _ip = ip;

    updateOptions();
  }

  OllamaModel.fromMap(VoidCallback listener, Map<String, dynamic> json) {
    addListener(listener);
    fromMap(json);
  }

  @override
  void fromMap(Map<String, dynamic> json) {
    super.fromMap(json);
    _ip = json['ip'] ?? '';
    notifyListeners();
  }

  @override
  Map<String, dynamic> toMap() {
    return {
      ...super.toMap(),
      'ip': _ip,
    };
  }

  @override
  Future<void> resetUri() async {
    if (_ip.isNotEmpty && (await _checkIpForOllama(_ip)).isNotEmpty) {
      uri = 'http://$_ip:11434';
      notifyListeners();
      return;
    }

    bool permissionGranted = await _getNearbyDevicesPermission();
    if (!permissionGranted) {
      return;
    }

    final localIP = await NetworkInfo().getWifiIP();

    // Get the first 3 octets of the local IP
    final baseIP = ipToCSubnet(localIP ?? '');

    // Scan the local network for hosts
    final hosts =
        await LanScanner(debugLogging: true).quickIcmpScanAsync(baseIP);

    // Create a list to hold all the futures
    var futures = <Future<String>>[];

    for (var host in hosts) {
      futures.add(_checkIpForOllama(host.internetAddress.address));
    }

    // Wait for all futures to complete
    final results = await Future.wait(futures);

    // Filter out all empty results and return the first valid URL, if any
    final validUrls = results.where((result) => result.isNotEmpty);
    _ip = validUrls.isNotEmpty ? validUrls.first : '';

    uri = 'http://$_ip:11434';

    await updateOptions();
    notifyListeners();
  }

  Future<String> _checkIpForOllama(String ip) async {
    final url = Uri.parse('http://$ip:11434');
    final headers = {"Accept": "application/json"};

    try {
      var request = Request("GET", url)..headers.addAll(headers);
      var response = await request.send();
      if (response.statusCode == 200) {
        Logger.log('Found Ollama at $ip');
        return ip;
      }
    } catch (e) {
      // Ignore
    }

    return '';
  }

  @override
  Stream<String> prompt(List<ChatNode> messages) async* {
    try {
      bool permissionGranted = await _getNearbyDevicesPermission();
      if (!permissionGranted) {
        throw Exception('Permission denied');
      }

      List<Map<String, dynamic>> chat = [];

      for (var message in messages) {
        chat.add({
          'role': message.role.name,
          'content': message.content,
        });
      }

      final url = Uri.parse("$uri/api/chat");

      final headers = {
        "Content-Type": "application/json",
        "User-Agent": "MAID"
      };

      var body = {
        "model": name,
        "messages": chat,
        "stream": true
      };

      if (!useDefault) {
        body['options'] = {
          "mirostat": mirostat,
          "mirostat_tau": mirostatTau,
          "mirostat_eta": mirostatEta,
          "num_ctx": nCtx,
          "num_thread": nThread,
          "repeat_last_n": penaltyLastN,
          "repeat_penalty": penaltyRepeat,
          "temperature": temperature,
          "seed": seed,
          "tfs_z": tfsZ,
          "num_predict": nPredict,
          "top_k": topK,
          "top_p": topP,          
        };
      }

      var request = Request("POST", url)
        ..headers.addAll(headers)
        ..body = json.encode(body);
        
      final streamedResponse = await request.send();

      final stream = streamedResponse.stream
          .transform(utf8.decoder)
          .transform(const LineSplitter());

      await for (final line in stream) {
        final data = json.decode(line);
        final responseText = data['message']['content'] as String?;
        final done = data['done'] as bool?;

        if (responseText != null && responseText.isNotEmpty) {
          yield responseText;
        }

        if (done ?? false) {
          break;
        }
      }
    } catch (e) {
      Logger.log('Error: $e');
    }
  }
  
  @override
  Future<void> updateOptions() async {
    bool permissionGranted = await _getNearbyDevicesPermission();
    if (!permissionGranted) {
      return;
    }

    final url = Uri.parse("$uri/api/tags");
    final headers = {"Accept": "application/json"};

    try {
      var request = Request("GET", url)..headers.addAll(headers);

      var response = await request.send();
      var responseString = await response.stream.bytesToString();
      var data = json.decode(responseString);

      List<String> newOptions = [];
      if (data['models'] != null) {
        for (var option in data['models']) {
          newOptions.add(option['name']);
        }
      }

      options = newOptions;
    } catch (e) {
      Logger.log('Error: $e');
    }
  }

  Future<bool> _getNearbyDevicesPermission() async {
    if (!Platform.isAndroid && !Platform.isIOS) {
      return true;
    }

    // Get sdk version
    final sdk = await DeviceInfoPlugin()
        .androidInfo
        .then((value) => value.version.sdkInt);
    var permissions = <Permission>[]; // List of permissions to request

    if (sdk <= 32) {
      // ACCESS_FINE_LOCATION is required
      permissions.add(Permission.location);
    } else {
      // NEARBY_WIFI_DEVICES is required
      permissions.add(Permission.nearbyWifiDevices);
    }

    // Request permissions and check if all are granted
    Map<Permission, PermissionStatus> statuses = await permissions.request();
    bool allPermissionsGranted =
        statuses.values.every((status) => status.isGranted);

    if (allPermissionsGranted) {
      Logger.log("Nearby Devices - permission granted");
      return true;
    } else {
      Logger.log("Nearby Devices - permission denied");
      return false;
    }
  }

  @override
  void save() {
    SharedPreferences.getInstance().then((prefs) {
      prefs.setString("ollama_model", json.encode(toMap()));
    });
  }
}