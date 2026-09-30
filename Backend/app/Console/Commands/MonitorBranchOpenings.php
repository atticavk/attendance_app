<?php

namespace App\Console\Commands;

use App\Services\BranchOpeningMonitorService;
use Illuminate\Console\Command;

class MonitorBranchOpenings extends Command
{
    protected $signature = 'branch-openings:monitor';

    protected $description = 'Send branch opening reminders and track overdue branch openings.';

    public function __construct(
        private readonly BranchOpeningMonitorService $branchOpeningMonitorService
    ) {
        parent::__construct();
    }

    public function handle(): int
    {
        $this->branchOpeningMonitorService->run();

        return self::SUCCESS;
    }
}
