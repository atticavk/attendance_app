<?php

namespace Tests\Feature;

use App\Models\Employee;
use App\Models\EmployeeAdvanceTransaction;
use App\Services\AdvanceImportService;
use Illuminate\Http\UploadedFile;
use Illuminate\Support\Facades\Config;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Facades\Storage;
use PhpOffice\PhpSpreadsheet\Shared\Date as ExcelDate;
use Tests\TestCase;

class AdvanceImportServiceTest extends TestCase
{
    protected function setUp(): void
    {
        parent::setUp();

        Config::set('database.default', 'sqlite');
        Config::set('database.connections.sqlite', [
            'driver' => 'sqlite',
            'database' => ':memory:',
            'prefix' => '',
            'foreign_key_constraints' => true,
        ]);

        DB::purge('sqlite');
        DB::setDefaultConnection('sqlite');
        DB::reconnect('sqlite');
        Storage::fake('local');

        Schema::create('employee', function ($table): void {
            $table->increments('id');
            $table->string('empId')->unique();
            $table->string('name')->nullable();
            $table->decimal('advance', 12, 2)->nullable();
            $table->decimal('pf', 12, 2)->nullable();
        });

        Schema::create('employee_advance_transactions', function ($table): void {
            $table->increments('id');
            $table->integer('employee_id');
            $table->string('emp_id', 50);
            $table->date('advance_date');
            $table->decimal('amount', 12, 2);
            $table->string('source_type', 20)->default('manual');
            $table->string('source_file')->nullable();
            $table->unsignedInteger('source_row_no')->nullable();
            $table->string('row_hash', 64)->nullable()->unique();
            $table->text('remarks')->nullable();
            $table->timestamps();
        });
    }

    public function test_manual_conflicts_require_confirmation_before_importing(): void
    {
        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
            'advance' => 5000,
            'pf' => 0,
        ]);

        EmployeeAdvanceTransaction::query()->create([
            'employee_id' => $employee->id,
            'emp_id' => '1000110',
            'advance_date' => '2026-04-22',
            'amount' => 5000,
            'source_type' => 'manual',
            'remarks' => 'Manual advance entry from salary module',
        ]);

        $file = UploadedFile::fake()->createWithContent(
            'advance.csv',
            implode("\n", [
                'SL. NO,ID,DATE,NAME,DESIGNATION,BRANCH,AMOUNT',
                '1,1000110,2026-04-22,Jayant K R,TE,HO,7000',
            ])
        );

        $service = $this->app->make(AdvanceImportService::class);
        $pendingImport = $service->prepareImport($file);

        $this->assertCount(1, $pendingImport['conflicts']);
        $this->assertSame([5000.0], $pendingImport['conflicts'][0]['manual_amounts']);
        $this->assertSame(12000.0, $pendingImport['conflicts'][0]['combined_total']);

        $this->expectException(\RuntimeException::class);
        $this->expectExceptionMessage('needs confirmation');
        $service->importPrepared($pendingImport['token']);
    }

    public function test_confirmed_manual_conflicts_are_imported_and_total_is_recalculated(): void
    {
        $employee = Employee::query()->create([
            'empId' => '1000110',
            'name' => 'Fixture Person 2',
            'advance' => 5000,
            'pf' => 0,
        ]);

        EmployeeAdvanceTransaction::query()->create([
            'employee_id' => $employee->id,
            'emp_id' => '1000110',
            'advance_date' => '2026-04-22',
            'amount' => 5000,
            'source_type' => 'manual',
            'remarks' => 'Manual advance entry from salary module',
        ]);

        $file = UploadedFile::fake()->createWithContent(
            'advance.csv',
            implode("\n", [
                'SL. NO,ID,DATE,NAME,DESIGNATION,BRANCH,AMOUNT',
                '1,1000110,2026-04-22,Jayant K R,TE,HO,7000',
            ])
        );

        $service = $this->app->make(AdvanceImportService::class);
        $pendingImport = $service->prepareImport($file);
        $result = $service->importPrepared($pendingImport['token'], true);

        $employee->refresh();

        $this->assertSame(1, $result['inserted']);
        $this->assertSame(1, $result['confirmed_conflicts']);
        $this->assertSame('12000', (string) $employee->advance);
        $this->assertDatabaseHas('employee_advance_transactions', [
            'employee_id' => $employee->id,
            'advance_date' => '2026-04-22',
            'amount' => 7000,
            'source_type' => 'import',
            'source_file' => 'advance.csv',
        ]);
    }

    public function test_numeric_excel_dates_are_imported_as_real_dates(): void
    {
        $employee = Employee::query()->create([
            'empId' => '2000220',
            'name' => 'Fixture Person 3',
            'advance' => 0,
            'pf' => 0,
        ]);

        $excelDate = (string) ExcelDate::dateTimeToExcel(new \DateTimeImmutable('2026-04-22'));
        $file = UploadedFile::fake()->createWithContent(
            'advance.csv',
            implode("\n", [
                'SL. NO,ID,DATE,NAME,DESIGNATION,BRANCH,AMOUNT',
                "1,2000220,{$excelDate},Employee Two,TE,HO,2500",
            ])
        );

        $service = $this->app->make(AdvanceImportService::class);
        $pendingImport = $service->prepareImport($file);
        $result = $service->importPrepared($pendingImport['token']);

        $employee->refresh();

        $this->assertSame(1, $result['inserted']);
        $this->assertSame('2500', (string) $employee->advance);
        $this->assertDatabaseHas('employee_advance_transactions', [
            'employee_id' => $employee->id,
            'advance_date' => '2026-04-22',
            'amount' => 2500,
            'source_type' => 'import',
        ]);
    }
}
