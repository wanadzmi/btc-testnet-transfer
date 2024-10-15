import 'dart:convert';
import 'package:bip32/bip32.dart' as bip32;
import 'package:bip39/bip39.dart' as bip39;
import 'package:flutter/material.dart';
import 'package:flutter_bitcoin/flutter_bitcoin.dart' as ftb;
import 'package:http/http.dart' as http;

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bitcoin Wallet',
      theme: ThemeData(primarySwatch: Colors.blue),
      home: const WalletPage(),
    );
  }
}

class WalletPage extends StatefulWidget {
  const WalletPage({super.key});

  @override
  _WalletPageState createState() => _WalletPageState();
}

class _WalletPageState extends State<WalletPage> {
  final String mnemonic =
      'spin pond apart swear axis address play real floor ripple category ski jelly balance rice';

  String? bitcoinAddress;
  String selectedFeeCategory = 'Normal';
  List<String> feeCategories = ['Economic', 'Normal', 'Priority'];
  String totalBalance = 'Fetching...';

  final TextEditingController recipientController =
      TextEditingController(text: 'mzBMzjm7BV1WFHC6mbLgNcaUsQATrfXP8k');
  final TextEditingController amountController = TextEditingController();

  @override
  void initState() {
    super.initState();
    generateBitcoinAddress();
    fetchBalance();
  }

  Future<void> generateBitcoinAddress() async {
    final seed = bip39.mnemonicToSeed(mnemonic);
    final node = bip32.BIP32.fromSeed(seed);
    final derivePath = node.derivePath("m/0'/0/0");

    final address = ftb
        .P2PKH(
          data: ftb.PaymentData(pubkey: derivePath.publicKey),
          network: ftb.testnet,
        )
        .data
        .address;

    print('Generated Bitcoin Address: $address (Testnet)');

    setState(() {
      bitcoinAddress = address;
    });
  }

  Future<void> fetchBalance() async {
    if (bitcoinAddress != null) {
      final url =
          'https://api.blockcypher.com/v1/btc/test3/addrs/$bitcoinAddress';
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final balanceSats = data['balance'] as int;

        setState(() {
          totalBalance = '${toBTC(balanceSats)} BTC';
        });

        print(
            'Total Balance: $balanceSats satoshis (${toBTC(balanceSats)} BTC)');
      } else {
        print('Failed to fetch balance: ${response.body}');
      }
    }
  }

  Future<List<dynamic>> getUTXOs(String address) async {
    final url = 'https://api.blockcypher.com/v1/btc/test3/addrs/$address/full';

    print(url);
    final response = await http.get(Uri.parse(url));

    if (response.statusCode != 200) {
      print('Failed to fetch UTXOs: ${response.body}');
      return [];
    }

    final data = jsonDecode(response.body);
    final utxos = data['txrefs'] ?? [];
    print('Fetched UTXOs: $utxos');
    return utxos;
  }

  Future<int> getFeeRate(String category) async {
    const url = 'https://api.blockcypher.com/v1/btc/test3';
    final response = await http.get(Uri.parse(url));

    if (response.statusCode != 200) {
      print('Failed to fetch fees: ${response.body}');
      return 1000;
    }

    final fees = jsonDecode(response.body);
    print('Fetched Fees: $fees');

    switch (category) {
      case 'Economic':
        return fees['low_fee_per_kb'];
      case 'Normal':
        return fees['medium_fee_per_kb'];
      case 'Priority':
      default:
        return fees['high_fee_per_kb'];
    }
  }

  int estimateTxSize(int numInputs, int numOutputs) {
    final size = (numInputs * 148) + (numOutputs * 34) + 10;
    print('Estimated Transaction Size: $size bytes');
    return size;
  }

  Future<int> calculateFee(
      String category, int numInputs, int numOutputs) async {
    final feeRate = await getFeeRate(category);
    final txSize = estimateTxSize(numInputs, numOutputs);
    final fee = (feeRate * txSize / 1000).ceil();
    print('Calculated Fee: $fee satoshis (${toBTC(fee)} BTC)');
    return fee;
  }

  Future<void> sendBitcoin(String recipientAddress, int amountSatoshi) async {
    if (bitcoinAddress == null) return;

    print('Starting Transaction');
    print('Recipient Address: $recipientAddress');
    print('Amount: $amountSatoshi satoshis (${toBTC(amountSatoshi)} BTC)');

    final seed = bip39.mnemonicToSeed(mnemonic);
    final node = bip32.BIP32.fromSeed(seed);
    final utxos = await getUTXOs(bitcoinAddress!);

    if (utxos.isEmpty) {
      print('No UTXOs available');
      return;
    }

    final txb = ftb.TransactionBuilder(network: ftb.testnet);

    num totalInput = 0;

    for (var utxo in utxos) {
      txb.addInput(utxo['txid'], utxo['vout']);
      totalInput += utxo['value'];
      print('Added UTXO: ${utxo['txid']} with ${utxo['value']} satoshis');
    }

    print(
        'Total Input Value: $totalInput satoshis (${toBTC(totalInput.toInt())} BTC)');

    final fee = await calculateFee(selectedFeeCategory, utxos.length, 1);

    if (totalInput < amountSatoshi + fee) {
      print('Insufficient total input value for transaction');
      return;
    }

    txb.addOutput(recipientAddress, amountSatoshi);
    print('Added Output: $recipientAddress - $amountSatoshi satoshis');

    final change = totalInput - amountSatoshi - fee;
    if (change > 0) {
      txb.addOutput(bitcoinAddress!, change.toInt());
      print('Added Change Output: $bitcoinAddress - $change satoshis');
    }

    final privateKey = node.derivePath("m/0'/0/0").privateKey;
    final keyPair =
        ftb.ECPair.fromPrivateKey(privateKey!, network: ftb.testnet);

    try {
      for (int i = 0; i < utxos.length; i++) {
        txb.sign(vin: i, keyPair: keyPair);
        print('Signed input $i');
      }
      print('Transaction signed successfully');
    } catch (e) {
      print('Error during signing: $e');
      return;
    }

    final txHex = txb.build().toHex();
    print('Transaction Hex: $txHex');
    await broadcastTransaction(txHex);
  }

  double toBTC(int satoshis) => satoshis / 100000000;

  Future<void> broadcastTransaction(String txHex) async {
    const url = 'https://api.blockcypher.com/v1/btc/test3/txs/push';
    final response = await http.post(
      Uri.parse(url),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'tx': txHex}),
    );

    if (response.statusCode == 201) {
      print('Transaction Broadcasted Successfully!');
    } else {
      print('Broadcast Failed: ${response.body}');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Bitcoin Wallet')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Bitcoin Address:',
                style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            SelectableText(bitcoinAddress ?? 'Generating...'),
            const SizedBox(height: 16),
            Text('Total Balance: $totalBalance'),
            const SizedBox(height: 16),
            DropdownButton<String>(
              value: selectedFeeCategory,
              items: feeCategories.map((String category) {
                return DropdownMenuItem<String>(
                  value: category,
                  child: Text(category),
                );
              }).toList(),
              onChanged: (String? newValue) {
                setState(() {
                  selectedFeeCategory = newValue!;
                });
              },
            ),
            const SizedBox(height: 16),
            TextField(
              controller: recipientController,
              decoration: const InputDecoration(labelText: 'Recipient Address'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: amountController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Amount (in BTC)'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () async {
                final recipient = recipientController.text;
                final btcAmount = double.tryParse(amountController.text) ?? 0.0;

                if (recipient.isEmpty || btcAmount <= 0) {
                  print('Invalid input');
                  return;
                }

                final amountSatoshi = (btcAmount * 100000000).toInt();
                await sendBitcoin(recipient, amountSatoshi);
              },
              child: const Text('Send Bitcoin'),
            ),
          ],
        ),
      ),
    );
  }
}
