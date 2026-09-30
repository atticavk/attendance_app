<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <title>Remaining ID Card Submissions</title>
    <style>
        @page { size: A4 landscape; margin: 14mm; }
        * { box-sizing: border-box; }
        body { color: #222; font-family: Arial, sans-serif; font-size: 12px; margin: 0; }
        h1 { font-size: 20px; margin: 0 0 5px; }
        p { color: #666; margin: 0 0 18px; }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid #bbb; padding: 7px 8px; text-align: left; }
        th { background: #f1f1f1; }
        td:first-child, th:first-child { text-align: center; width: 55px; }
        .actions { margin-bottom: 15px; }
        .actions button { background: #7d123d; border: 0; border-radius: 4px; color: white; cursor: pointer; padding: 9px 16px; }
        @media print { .actions { display: none; } }
    </style>
</head>
<body>
    <div class="actions"><button type="button" onclick="window.print()">Save as PDF / Print</button></div>
    <h1>Remaining ID Card Submissions</h1>
    <p>Active HO employees yet to submit ID-card details — {{ $employees->count() }} employee(s)</p>
    <table>
        <thead>
            <tr>
                <th>Sl.No</th>
                <th>Employee ID</th>
                <th>Name</th>
                <th>Designation</th>
                <th>Contact</th>
            </tr>
        </thead>
        <tbody>
            @forelse($employees as $employee)
                <tr>
                    <td>{{ $loop->iteration }}</td>
                    <td>{{ $employee->empId }}</td>
                    <td>{{ $employee->name }}</td>
                    <td>{{ $employee->designation ?: '—' }}</td>
                    <td>{{ $employee->contact ?: '—' }}</td>
                </tr>
            @empty
                <tr><td colspan="5">No remaining submissions.</td></tr>
            @endforelse
        </tbody>
    </table>
    <script>window.addEventListener('load', () => window.print());</script>
</body>
</html>
