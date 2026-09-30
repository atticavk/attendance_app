<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Mobile API Status</title>
    <style>
        * { box-sizing: border-box; }
        body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 24px; background: #f4f6f8; color: #17202a; font-family: Arial, sans-serif; }
        .card { width: min(100%, 440px); padding: 32px; background: #fff; border-radius: 14px; box-shadow: 0 12px 35px rgba(0,0,0,.1); }
        h1 { margin: 0 0 12px; font-size: 25px; }
        .state { margin: 0 0 24px; font-weight: 700; color: {{ $disabled ? '#f10505' : '#0ee09a' }}; }
        label { display: block; margin-bottom: 8px; font-weight: 600; }
        input { width: 100%; padding: 12px; border: 1px solid #c8ced5; border-radius: 8px; font-size: 16px; }
        .actions { display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin-top: 18px; }
        button { padding: 12px; border: 0; border-radius: 8px; color: #fff; font-weight: 700; cursor: pointer; }
        .activate { background: #020202; }
        .deactivate { background: #020202; }
        .message { padding: 10px 12px; margin-bottom: 18px; border-radius: 8px; background: #ecfdf3; color: #067647; }
        .error { margin: 8px 0 0; color: #000000; font-size: 14px; }
    </style>
</head>
<body>
<main class="card">
    <h1>Status</h1>
    <p class="state">Currently {{ $disabled ? 'OFF' : 'ON' }}</p>

    @if (session('status'))
        <div class="message">{{ session('status') }}</div>
    @endif

    <form method="POST" action="{{ route('mobile-api.status.update') }}">
        @csrf
        <label for="password">Emergency password</label>
        <input id="password" name="password" type="password" required autocomplete="current-password" autofocus>
        @error('password') <p class="error">{{ $message }}</p> @enderror

        <label for="totp_code" style="margin-top:16px">Google Authenticator code</label>
        <input id="totp_code" name="totp_code" type="text" required inputmode="numeric" pattern="[0-9]{6}" maxlength="6" autocomplete="one-time-code" placeholder="000000">
        @error('totp_code') <p class="error">{{ $message }}</p> @enderror
        @error('action') <p class="error">{{ $message }}</p> @enderror

        <div class="actions">
            <button class="activate" type="submit" name="action" value="activate">ON</button>
            <button class="deactivate" type="submit" name="action" value="deactivate">OFF</button>
        </div>
    </form>
</main>
</body>
</html>
