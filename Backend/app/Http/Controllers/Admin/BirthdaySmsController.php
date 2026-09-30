<?php

namespace App\Http\Controllers\Admin;

use App\Http\Controllers\Controller;
use App\Models\BirthdaySmsDelivery;
use App\Models\BirthdaySmsSetting;
use Illuminate\Http\RedirectResponse;
use Illuminate\Http\Request;
use Illuminate\View\View;

class BirthdaySmsController extends Controller
{
    public function edit(): View
    {
        return view('admin.birthday_sms.edit', [
            'setting' => BirthdaySmsSetting::current(),
            'recentDeliveries' => BirthdaySmsDelivery::query()->latest()->limit(25)->get(),
        ]);
    }

    public function update(Request $request): RedirectResponse
    {
        $data = $request->validate([
            'enabled' => ['nullable', 'boolean'],
            'send_time' => ['required', 'date_format:H:i'],
            'provider_template_id' => ['nullable', 'string', 'max:255'],
            'message_template' => ['required', 'string', 'max:1000', 'regex:/\{\{name\}\}/'],
        ], ['message_template.regex' => 'The SMS template must include {{name}}.']);

        BirthdaySmsSetting::current()->update([
            'enabled' => $request->boolean('enabled'),
            'send_time' => $data['send_time'].':00',
            'provider_template_id' => $data['provider_template_id'] ?? null,
            'message_template' => $data['message_template'],
            'updated_by' => $request->user('admin')?->id,
        ]);

        return back()->with('status', 'Birthday SMS settings updated.');
    }
}
