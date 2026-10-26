import 'dart:convert';
import 'package:shelf/shelf.dart';
import 'package:test/test.dart';

import '../lib/src/api.dart';
import '../lib/src/database.dart';

void main() {
  group('Multi-currency Accounts & Currency Immutability Tests', () {
    late AppDatabase db;
    late Api api;

    Future<Response> send(
      String method,
      String path, {
      String? token,
      Map<String, dynamic>? body,
    }) async {
      final headers = <String, String>{
        'content-type': 'application/json',
        if (token != null) 'authorization': 'Bearer $token',
      };
      final uri = Uri.parse('http://localhost$path');
      final request = Request(
        method,
        uri,
        headers: headers,
        body: body != null ? jsonEncode(body) : null,
      );
      return await api.router.call(request);
    }

    setUp(() {
      db = AppDatabase.inMemory();
      api = Api(db);
    });

    tearDown(() {
      db.close();
    });

    Future<Map<String, String>> registerAndLogin(String email, String password, String name, double balance) async {
      final reg = await send('POST', '/api/auth/register', body: {
        'name': name,
        'email': email,
        'password': password,
        'opening_balance': balance,
      });
      expect(reg.statusCode, 201);

      final login = await send('POST', '/api/auth/login', body: {
        'email': email,
        'password': password,
      });
      expect(login.statusCode, 200);
      final data = jsonDecode(await login.readAsString());
      return {
        'token': data['token'] as String,
        'userId': data['user']['id'] as String,
      };
    }

    test('Historic user gets automatic default CRC account created on first query', () async {
      final user = await registerAndLogin('historic@test.com', 'Pass1234!', 'Usuario Histórico', 50000);
      final token = user['token']!;

      final res = await send('GET', '/api/accounts', token: token);
      expect(res.statusCode, 200);
      final accounts = jsonDecode(await res.readAsString()) as List;
      expect(accounts.length, 1);
      final defaultAcc = accounts.first;
      expect(defaultAcc['currency'], 'CRC');
      expect(defaultAcc['name'], 'Efectivo Costa Rica');
      expect(defaultAcc['initial_balance'], 50000.0);
      expect(defaultAcc['current_balance'], 50000.0);
      expect(defaultAcc['is_default'], true);
    });

    test('Can create USD and EUR accounts with ISO 4217 validation', () async {
      final user = await registerAndLogin('multicurrency@test.com', 'Pass1234!', 'Viajero Frecuente', 100000);
      final token = user['token']!;

      // Attempt invalid currency code (only 2 chars)
      final invalidRes = await send('POST', '/api/accounts', token: token, body: {
        'name': 'Cuenta Inválida',
        'currency': 'US',
        'initial_balance': 100,
      });
      expect(invalidRes.statusCode, 400);

      // Create USD account
      final usdRes = await send('POST', '/api/accounts', token: token, body: {
        'name': 'Ahorros Dólares',
        'currency': 'USD',
        'initial_balance': 500.0,
        'color': '#2563EB',
        'icon': 'attach_money',
      });
      expect(usdRes.statusCode, 201);
      final usdData = jsonDecode(await usdRes.readAsString());
      expect(usdData['currency'], 'USD');
      expect(usdData['initial_balance'], 500.0);

      // Create EUR account
      final eurRes = await send('POST', '/api/accounts', token: token, body: {
        'name': 'Viaje Europa',
        'currency': 'EUR',
        'initial_balance': 300.0,
        'color': '#8B5CF6',
        'icon': 'euro',
      });
      expect(eurRes.statusCode, 201);
      final eurData = jsonDecode(await eurRes.readAsString());
      expect(eurData['currency'], 'EUR');
      expect(eurData['initial_balance'], 300.0);

      // List all accounts: should have CRC, USD, EUR
      final listRes = await send('GET', '/api/accounts', token: token);
      expect(listRes.statusCode, 200);
      final allAccounts = jsonDecode(await listRes.readAsString()) as List;
      expect(allAccounts.length, 3);
      final currencies = allAccounts.map((a) => a['currency']).toSet();
      expect(currencies, containsAll(['CRC', 'USD', 'EUR']));
    });

    test('STRICT CURRENCY IMMUTABILITY: Cannot change currency via PATCH/PUT or update', () async {
      final user = await registerAndLogin('immutable@test.com', 'Pass1234!', 'Inmutable Test', 0);
      final token = user['token']!;

      // Create account in CRC
      final createRes = await send('POST', '/api/accounts', token: token, body: {
        'name': 'Cuenta CRC Original',
        'currency': 'CRC',
        'initial_balance': 1000,
      });
      expect(createRes.statusCode, 201);
      final accountId = jsonDecode(await createRes.readAsString())['id'];

      // Attempt to PATCH currency from CRC to USD: MUST BE REJECTED (HTTP 400)
      final patchRes = await send('PATCH', '/api/accounts/$accountId', token: token, body: {
        'currency': 'USD',
        'name': 'Intento Malicioso',
      });
      expect(patchRes.statusCode, 400);
      final errorMsg = jsonDecode(await patchRes.readAsString())['message'].toString().toLowerCase();
      expect(errorMsg, contains('inmutable'));

      // Verify the account in DB is STILL CRC
      final getRes = await send('GET', '/api/accounts/$accountId', token: token);
      expect(getRes.statusCode, 200);
      final getAccount = jsonDecode(await getRes.readAsString());
      expect(getAccount['currency'], 'CRC');
      expect(getAccount['name'], 'Cuenta CRC Original');
    });

    test('Account Isolation: balances and transactions are strictly segregated', () async {
      final user = await registerAndLogin('isolation@test.com', 'Pass1234!', 'Usuario Aislado', 20000);
      final token = user['token']!;

      // Get default CRC account
      final accRes = await send('GET', '/api/accounts', token: token);
      final defaultCrcAcc = (jsonDecode(await accRes.readAsString()) as List).first;
      final crcId = defaultCrcAcc['id'];

      // Create USD account
      final usdRes = await send('POST', '/api/accounts', token: token, body: {
        'name': 'Dólares Efectivo',
        'currency': 'USD',
        'initial_balance': 100.0,
      });
      final usdId = jsonDecode(await usdRes.readAsString())['id'];

      // Post income 5000 in CRC
      await send('POST', '/api/transactions', token: token, body: {
        'account_id': crcId,
        'type': 'income',
        'amount': 5000.0,
        'category': 'Salario',
        'description': 'Pago quincena CRC',
      });

      // Post expense 20 in USD
      await send('POST', '/api/transactions', token: token, body: {
        'account_id': usdId,
        'type': 'expense',
        'amount': 20.0,
        'category': 'Compras',
        'description': 'Amazon USD',
      });

      // CRC Dashboard verification
      final crcDashRes = await send('GET', '/api/dashboard?account_id=$crcId', token: token);
      expect(crcDashRes.statusCode, 200);
      final crcDash = jsonDecode(await crcDashRes.readAsString());
      expect(crcDash['currency'], 'CRC');
      expect(crcDash['opening_balance'], 20000.0);
      expect(crcDash['income'], 5000.0);
      expect(crcDash['expenses'], 0.0); // 0 expenses in CRC!
      expect(crcDash['balance'], 25000.0);

      // USD Dashboard verification
      final usdDashRes = await send('GET', '/api/dashboard?account_id=$usdId', token: token);
      expect(usdDashRes.statusCode, 200);
      final usdDash = jsonDecode(await usdDashRes.readAsString());
      expect(usdDash['currency'], 'USD');
      expect(usdDash['opening_balance'], 100.0);
      expect(usdDash['income'], 0.0); // 0 income in USD!
      expect(usdDash['expenses'], 20.0);
      expect(usdDash['balance'], 80.0);
    });

    test('User Isolation: User A cannot see or write to User B accounts', () async {
      final userA = await registerAndLogin('usera@test.com', 'Pass1234!', 'User A', 1000);
      final userB = await registerAndLogin('userb@test.com', 'Pass1234!', 'User B', 2000);

      // Get User A account ID
      final resA = await send('GET', '/api/accounts', token: userA['token']);
      final accountAId = (jsonDecode(await resA.readAsString()) as List).first['id'];

      // User B attempts to access User A account: MUST RETURN 404
      final unauthorizedGet = await send('GET', '/api/accounts/$accountAId', token: userB['token']);
      expect(unauthorizedGet.statusCode, 404);

      // User B attempts to post transaction into User A account: MUST BE REJECTED (HTTP 400)
      final unauthorizedTx = await send('POST', '/api/transactions', token: userB['token'], body: {
        'account_id': accountAId,
        'type': 'expense',
        'amount': 500,
        'description': 'Ataque cruzado',
      });
      expect(unauthorizedTx.statusCode, 400);

      // User B attempts to query dashboard with User A account: MUST RETURN 404
      final unauthorizedDash = await send('GET', '/api/dashboard?account_id=$accountAId', token: userB['token']);
      expect(unauthorizedDash.statusCode, 404);
    });

    test('Account Deletion: cannot delete only active account, default transitions smoothly', () async {
      final user = await registerAndLogin('deleteacc@test.com', 'Pass1234!', 'Delete Account Test', 5000);
      final token = user['token']!;

      // Get only account
      final res = await send('GET', '/api/accounts', token: token);
      final defaultAcc = (jsonDecode(await res.readAsString()) as List).first;
      final acc1Id = defaultAcc['id'];

      // Try deleting the only account -> MUST BE REJECTED (HTTP 400)
      final delOnlyRes = await send('DELETE', '/api/accounts/$acc1Id', token: token);
      expect(delOnlyRes.statusCode, 400);

      // Create second account
      final acc2Res = await send('POST', '/api/accounts', token: token, body: {
        'name': 'Segunda Cuenta USD',
        'currency': 'USD',
        'initial_balance': 50,
      });
      expect(acc2Res.statusCode, 201);
      final acc2Id = jsonDecode(await acc2Res.readAsString())['id'];

      // Now delete first account
      final delRes = await send('DELETE', '/api/accounts/$acc1Id', token: token);
      expect(delRes.statusCode, 200);

      // Verify acc2 is now the default account
      final acc2Get = await send('GET', '/api/accounts/$acc2Id', token: token);
      expect(acc2Get.statusCode, 200);
      final acc2Data = jsonDecode(await acc2Get.readAsString());
      expect(acc2Data['is_default'], true);
    });
  });
}
