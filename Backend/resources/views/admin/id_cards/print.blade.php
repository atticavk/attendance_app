<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>{{ $submission->emp_id }} ID Card</title>
    @include('admin.id_cards.partials.card_styles')
    <style>
        @page {
            size: A4 portrait;
            margin: 0;
        }

        * {
            box-sizing: border-box;
        }

        html,
        body {
            margin: 0;
            padding: 0;
        }

        body {
            background: #ececec;
        }

        .print-page {
            align-items: center;
            background: #fff;
            display: flex;
            height: 297mm;
            justify-content: center;
            margin: 0 auto 12px;
            overflow: hidden;
            page-break-after: always;
            break-after: page;
            width: 210mm;
        }

        .print-page:last-child {
            page-break-after: auto;
            break-after: auto;
        }

        .card-frame {
            height: 324px;
            overflow: visible;
            position: relative;
            width: 204px;
        }

        .card-frame .supplied-card {
            border-radius: 0 !important;
            box-shadow: none !important;
            height: 540px !important;
            margin: 0 !important;
            transform: scale(.6) !important;
            transform-origin: top left !important;
            width: 340px !important;
            zoom: 1 !important;
        }

        .supplied-card .supplied-side-block,
        .supplied-card .supplied-side-block span,
        .supplied-card .supplied-side-block strong,
        .supplied-card .supplied-side-block svg {
            color: #fff !important;
        }

        .supplied-card .supplied-side-block svg {
            stroke: #fff !important;
        }

        .print-actions {
            background: #fff;
            border-radius: 8px;
            box-shadow: 0 3px 16px rgba(0, 0, 0, .15);
            left: 16px;
            padding: 10px;
            position: fixed;
            top: 16px;
            z-index: 100;
        }

        .print-actions button {
            background: #651226;
            border: 0;
            border-radius: 6px;
            color: #fff;
            cursor: pointer;
            font: 600 14px Arial, sans-serif;
            padding: 10px 16px;
        }

        @media print {
            body {
                background: #fff !important;
            }

            .print-actions {
                display: none !important;
            }

            .print-page {
                margin: 0 !important;
            }
        }
    </style>
</head>
<body>
    <div class="print-actions">
        <button type="button" onclick="window.print()">Print / Save PDF</button>
    </div>

    <section class="print-page" aria-label="ID card front">
        <div class="card-frame">
            @include('admin.id_cards.partials.card_faces', [
                'idPrefix' => 'print',
                'submission' => $submission,
            ])
        </div>
    </section>

    <script>
        const backCard = document.getElementById('printBack');
        const backPage = document.createElement('section');
        backPage.className = 'print-page';
        backPage.setAttribute('aria-label', 'ID card back');

        const backFrame = document.createElement('div');
        backFrame.className = 'card-frame';
        backFrame.appendChild(backCard);
        backPage.appendChild(backFrame);
        document.body.appendChild(backPage);

        window.addEventListener('load', () => {
            setTimeout(() => window.print(), 250);
        });
    </script>
</body>
</html>
