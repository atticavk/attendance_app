<?php

namespace App\Services;

use App\Models\BirthdaySmsDelivery;
use App\Models\BirthdaySmsSetting;
use App\Models\Employee;
use Illuminate\Support\Carbon;
use Illuminate\Support\Facades\Http;
use RuntimeException;

class BirthdaySmsService
{
    public function sendDue(?Carbon $now = null): int
    {
        $now ??= now();
        $setting = BirthdaySmsSetting::current();
        if (! $setting->enabled || substr((string) $setting->send_time, 0, 5) !== $now->format('H:i')) {
            return 0;
        }

        $sent = 0;
        Employee::query()
            ->whereNotNull('date_of_birth')
            ->whereNotNull('contact')
            ->where('contact', '!=', '')
            ->where(function ($query): void {
                $query->whereNull('status')->orWhereRaw('LOWER(TRIM(status)) != ?', ['inactive']);
            })
            ->whereMonth('date_of_birth', $now->month)
            ->whereDay('date_of_birth', $now->day)
            ->orderBy('id')
            ->chunkById(100, function ($employees) use ($setting, $now, &$sent): void {
                foreach ($employees as $employee) {
                    $delivery = BirthdaySmsDelivery::query()->firstOrCreate(
                        ['employee_id' => $employee->id, 'birthday_date' => $now->toDateString()],
                        ['phone' => trim((string) $employee->contact), 'status' => 'pending']
                    );
                    if (! $delivery->wasRecentlyCreated && $delivery->status === 'sent') {
                        continue;
                    }

                    try {
                        $response = $this->send(
                            $delivery->phone,
                            str_replace('{{name}}', $this->firstName((string) $employee->name), $setting->message_template),
                            $setting->provider_template_id
                        );
                        $delivery->update(['status' => 'sent', 'provider_response' => $response, 'sent_at' => now()]);
                        $sent++;
                    } catch (\Throwable $error) {
                        $delivery->update(['status' => 'failed', 'provider_response' => mb_substr($error->getMessage(), 0, 2000)]);
                        report($error);
                    }
                }
            });

        return $sent;
    }

    private function send(string $phone, string $message, ?string $templateId): string
    {
        $endpoint = trim((string) config('services.birthday_sms.endpoint'));
        if ($endpoint === '') {
            throw new RuntimeException('Birthday SMS provider endpoint is not configured.');
        }

        $request = Http::timeout((int) config('services.birthday_sms.timeout', 15))->acceptJson();
        $token = trim((string) config('services.birthday_sms.token'));
        if ($token !== '') {
            $request = $request->withToken($token);
        }

        $response = $request->post($endpoint, [
            'to' => $phone,
            'message' => $message,
            'sender_id' => config('services.birthday_sms.sender_id'),
            'template_id' => $templateId,
        ]);
        $response->throw();

        return mb_substr($response->body(), 0, 2000);
    }

    private function firstName(string $name): string
    {
        return preg_split('/\s+/', trim($name), 2)[0] ?? '';
    }
}
