import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:dart_jsonwebtoken/dart_jsonwebtoken.dart';

Future<void> sendFcmPush({
  required String fcmToken,
  required String projectId,
  required String title,
  required String body,
}) async {
  // ⚠️ Don’t hardcode private keys in production. Store securely.
  const serviceAccountJson = {
    "type": "service_account",
    "project_id": "movieflix-53a51",
    "private_key_id": "6d57543310e4be2541b4afd8ff58a23d59f1dd75",
    "private_key": "-----BEGIN PRIVATE KEY-----\nMIIEvgIBADANBgkqhkiG9w0BAQEFAASCBKgwggSkAgEAAoIBAQDiYMC3Jgb6JsDz\nwHDYbWbRvo20IaV0ga70bbgvAgcFTqW74qUJ6QY/b4oKlMmXIml7wFWM1gHTzsZX\n0CGPLc0Cv3FspA1d6NKJJhRMh3vdpPvw9U1FQ9HywHm/0fFQN1eAeP2aFFkaJ+Cr\nRHJPwds+NLzBqjEzAAFTVHI0DrHREy5N8czmWQt43LpI2lBCqj/F2Wd+DbT9PHQj\n1nH0Jnqma+ifcI+QW8enIZLazKPvvZiCihwmMgUgmatM67SZOgNCRBPyUNWF6cXf\npSYHzpI6lwKk2JKSSTghfG3S9f/6rk3+bntI8K9EjQQaKF2wGt61TpBiU/vSd8WG\n/6aV3e/lAgMBAAECggEAIi/3wAZff1+4PBeP8zTHwQfvYTNuR/izHKQv8J7Jw09r\n+sKbp1zTCLl7i2WKRud3hAI5PppYjvg8k/5mqGIuV9U5opfpPN7Ft4NSBXdgiXSP\nvTAOigCtWuUefeLizU549Hn73U0St78rUDIiC/wmyW+Fd2nlzDdFUU8A1ZkdLt8B\n3XpsXlR98WsogPv6O2X7C/w6QmkannbGZyP2k69EzY8/uK/XxglTPYCz34ENUsMR\n/AMV0mR8tgjcgjM8nY7Vo1Wl0va1+rCf2xk2/4p1cV22SRHxcvlQUoiO/HDBluvQ\nJ8DqcIzJ4LsdOJ40tTINFQxF/5bCAlGAfUJhaLk6cQKBgQD+gTxKv/W1kSEz459e\nqzuCFBOFYunmo7F47cIIydWwz81Id6qmIQWZXOnobGlyg/3kRYiICol0HyrrpM01\nYgbeUAwRR7hABa5BAwcEhq1CchPSTsD1yHu+vNTb7QNZa06pK2x6vyVHkwr95rLU\nubaBMUD7b8+rQst5N4dg6EdiMwKBgQDjtTczxmv8HpuktMe915La446cX4t7qQAT\n/h1MckcM5RpeJewLAvLknuKwDBvi3QegHxPyh+OhzgF2FboIAbCG3mgxn1bccJOs\nAxzIirbkf1ofkorxMJKWgSciTj6S6RuomDatNpiuJXagm6kPM/MeZIfu7bQbfePj\nXOFSHeE9hwKBgQDLdTVl7J/ZTvRkLwww+mLQUoxojfK/Vw2Bx1DfBbu3ZeiOjlv2\nA2AegpDcJg8GZU6LNqs3VnUcR+5gA5epnXwwLX34MoWxaNktT+ZEUAYioGAIOL05\nv9RtXzgruQZ8bbSsuPI4DqcW2Q5ofA1q0ix8i4uPdotmNjfD6AhqCEdI0QKBgQDF\n8DvpNN2fjtfLSB6tZtxQjCjmw6NTPmhD+MxtLJWYnvrZxms2czzDAV6anBwNjAdZ\n6EoFtJxqhdH9XQuWdCmIQ4MdR55RB0dG6nm11ecAH7gu48sFuCxkyiZDivKX8CzL\n1G0LCv+Tuhsxp75A6e63h7omNtkuYLOda5quMC0gtwKBgADeax57DpM5MrfOJtA1\nNEv34uwlOVc/XpxMyQtG+iP1Y/m4f2Q1zzrT7CqJvX25hwrzECv3oCvDQEpzzgTA\nMFHCLwLpE5Y7IL4scK78CRFtTrbK4RoUXjqjRQVSPnY11SkYphSol2hLBx50HQKK\nN7bCFIXj83sDbaqE8BvlekKC\n-----END PRIVATE KEY-----\n",
    "client_email": "firebase-adminsdk-fbsvc@movieflix-53a51.iam.gserviceaccount.com",
    "token_uri": "https://oauth2.googleapis.com/token",
  };

  // Create JWT
  final jwt = JWT(
    {
      'iss': serviceAccountJson['client_email'],
      'scope': 'https://www.googleapis.com/auth/firebase.messaging',
      'aud': serviceAccountJson['token_uri'],
      'iat': DateTime.now().millisecondsSinceEpoch ~/ 1000,
      'exp': DateTime.now().add(Duration(minutes: 60)).millisecondsSinceEpoch ~/ 1000,
    },
  );

  final privateKeyPem = serviceAccountJson['private_key']!;
  final key = RSAPrivateKey(privateKeyPem);

  final signedJwt = jwt.sign(key, algorithm: JWTAlgorithm.RS256);

  // Exchange JWT for OAuth2 access token
  final oauthResponse = await http.post(
    Uri.parse(serviceAccountJson['token_uri']!),
    headers: {'Content-Type': 'application/x-www-form-urlencoded'},
    body: {
      'grant_type': 'urn:ietf:params:oauth:grant-type:jwt-bearer',
      'assertion': signedJwt,
    },
  );

  if (oauthResponse.statusCode != 200) {
    throw Exception('Failed to obtain access token: ${oauthResponse.body}');
  }

  final accessToken = jsonDecode(oauthResponse.body)['access_token'];

  // Send FCM push
  final response = await http.post(
    Uri.parse('https://fcm.googleapis.com/v1/projects/$projectId/messages:send'),
    headers: {
      'Content-Type': 'application/json',
      'Authorization': 'Bearer $accessToken',
    },
    body: jsonEncode({
      'message': {
        'token': fcmToken,
        'notification': {
          'title': title,
          'body': body,
        },
        'data': {
          'click_action': 'FLUTTER_NOTIFICATION_CLICK',
          'customKey': 'customValue',
        },
      },
    }),
  );

  if (response.statusCode == 200) {
    print('✅ Push sent: ${response.body}');
  } else {
    print('❌ Error: ${response.statusCode} ${response.body}');
  }
}
