<?php

namespace App\Console\Commands;

use App\Services\BirthdaySmsService;
use Illuminate\Console\Command;

class SendBirthdaySms extends Command
{
    protected $signature = 'birthdays:send-sms';
    protected $description = 'Send due birthday SMS messages to active employees';

    public function handle(BirthdaySmsService $service): int
    {
        $this->info($service->sendDue().' birthday SMS message(s) sent.');

        return self::SUCCESS;
    }
}
