<?php

namespace Tests\Unit;

use App\Support\ExcelTextValue;
use PhpOffice\PhpSpreadsheet\Cell\DataType;
use PhpOffice\PhpSpreadsheet\Spreadsheet;
use PhpOffice\PhpSpreadsheet\Style\NumberFormat;
use Tests\TestCase;

class ExcelTextValueTest extends TestCase
{
    public function test_csv_value_preserves_all_digits_and_leading_zeroes(): void
    {
        $this->assertSame('01892210021316', ExcelTextValue::forCsv('01892210021316'));
        $this->assertSame('500100000000000', ExcelTextValue::forCsv('500100000000000'));
        $this->assertSame('', ExcelTextValue::forCsv(''));
        $this->assertSame("'=HYPERLINK(\"https://example.test\")", ExcelTextValue::forCsv('=HYPERLINK("https://example.test")'));
    }

    public function test_spreadsheet_cell_is_written_as_text(): void
    {
        $spreadsheet = new Spreadsheet();
        $sheet = $spreadsheet->getActiveSheet();

        ExcelTextValue::setCell($sheet, 'A1', '01892210021316');

        $this->assertSame('01892210021316', $sheet->getCell('A1')->getValue());
        $this->assertSame(DataType::TYPE_STRING, $sheet->getCell('A1')->getDataType());
        $this->assertSame(NumberFormat::FORMAT_TEXT, $sheet->getStyle('A1')->getNumberFormat()->getFormatCode());
    }

    public function test_spreadsheet_formula_text_is_neutralized(): void
    {
        $spreadsheet = new Spreadsheet();
        $sheet = $spreadsheet->getActiveSheet();

        ExcelTextValue::setCell($sheet, 'A1', '=1+1');

        $this->assertSame("'=1+1", $sheet->getCell('A1')->getValue());
        $this->assertSame(DataType::TYPE_STRING, $sheet->getCell('A1')->getDataType());
    }
}
