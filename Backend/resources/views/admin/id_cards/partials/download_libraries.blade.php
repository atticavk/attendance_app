@php
    $html2canvasSource = file_get_contents(public_path('id-card-assets/html2canvas.min.js'));
    $jsZipSource = $includeJsZip
        ? file_get_contents(public_path('id-card-assets/jszip.min.js'))
        : null;
@endphp
<script>{!! $html2canvasSource !!}</script>
@if($jsZipSource)
<script>{!! $jsZipSource !!}</script>
@endif
