<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Approved ID Card Submissions</title>
    @include('admin.id_cards.partials.card_styles')
    <style>
        @page { size: A4 landscape; margin: 0; }
        * { box-sizing: border-box; }
        html, body { margin: 0; padding: 0; }
        body { background: #e9ecef; color: #24151a; font-family: Arial, sans-serif; }
        .print-actions {
            background: #fff; border-radius: 8px; box-shadow: 0 3px 16px rgba(0, 0, 0, .15);
            left: 16px; padding: 10px; position: fixed; top: 16px; z-index: 100;
        }
        .print-actions button {
            background: #651226; border: 0; border-radius: 6px; color: #fff; cursor: pointer;
            font: 600 14px Arial, sans-serif; padding: 10px 16px;
        }
        .approved-page {
            align-items: center; background: #fff; display: flex; flex-direction: column; height: 210mm;
            justify-content: center; margin: 0 auto 12px; overflow: hidden; page-break-after: always;
            break-after: page; width: 297mm;
        }
        .approved-page:last-of-type { break-after: auto; page-break-after: auto; }
        .employee-id { font-size: 24px; font-weight: 700; letter-spacing: .04em; margin: 0 0 8mm; }
        .card-pair { display: flex; gap: 12mm; justify-content: center; }
        .card-frame { height: 540px; overflow: visible; position: relative; width: 340px; }
        .card-frame .supplied-card {
            border-radius: 0 !important; box-shadow: none !important; height: 540px !important;
            margin: 0 !important; transform: none !important; transform-origin: top left !important;
            width: 340px !important; zoom: 1 !important;
        }
        .supplied-card .supplied-side-block,
        .supplied-card .supplied-side-block span,
        .supplied-card .supplied-side-block strong,
        .supplied-card .supplied-side-block svg { color: #fff !important; }
        .supplied-card .supplied-side-block svg { stroke: #fff !important; }
        .empty-state { background: #fff; margin: 40px auto; max-width: 680px; padding: 32px; text-align: center; }
        @media print {
            body { background: #fff !important; }
            .print-actions { display: none !important; }
            .approved-page { margin: 0 !important; }
        }
    </style>
</head>
<body>
    <div class="print-actions"><button type="button" onclick="window.print()">Download / Save PDF</button></div>

    @forelse($submissions as $submission)
        <section class="approved-page" aria-label="Approved ID card {{ $submission->emp_id }}">
            <h1 class="employee-id">Employee ID: {{ $submission->emp_id }}</h1>
            <div class="card-pair">
                <div class="card-frame">
                    @include('admin.id_cards.partials.card_faces', [
                        'idPrefix' => 'approved'.$submission->id,
                        'submission' => $submission,
                    ])
                </div>
                <div class="card-frame" data-back-frame></div>
            </div>
        </section>
    @empty
        <div class="empty-state"><h1>No approved ID cards</h1><p>Approve at least one active submission before downloading this PDF.</p></div>
    @endforelse

    <script>
        document.querySelectorAll('.approved-page').forEach((page) => {
            const frontFrame = page.querySelector('.card-frame');
            const backFrame = page.querySelector('[data-back-frame]');
            const backCard = frontFrame.querySelector('.supplied-back');
            if (backCard) backFrame.appendChild(backCard);
        });

        @if($submissions->isNotEmpty())
        window.addEventListener('load', () => setTimeout(() => window.print(), 250));
        @endif
    </script>
</body>
</html>
