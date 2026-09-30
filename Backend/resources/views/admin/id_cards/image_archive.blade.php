@extends('admin.layout.app')

@section('content')
<link rel="stylesheet" href="/id-card-assets/app.css">
@include('admin.id_cards.partials.card_styles')
<script src="{{ route('admin-id-cards-html2canvas', [], false) }}"></script>
<script src="{{ route('admin-id-cards-jszip', [], false) }}"></script>
<style>
    .zip-card-render-area{position:fixed;left:-10000px;top:0;width:340px;z-index:-1}
    .zip-card-render-area .supplied-card{margin:0}
    .supplied-card .supplied-side-block,
    .supplied-card .supplied-side-block span,
    .supplied-card .supplied-side-block strong,
    .supplied-card .supplied-side-block svg{color:#fff!important}
    .supplied-card .supplied-side-block svg{stroke:#fff!important}
</style>
<div class="main-content">
    <div class="d-flex align-items-center justify-content-between gap-3 mb-3">
        <div><h4 class="mb-1">Download All ID Cards</h4><p class="text-muted mb-0">Creates front and back PNG images using the official card design.</p></div>
        <a href="{{ route('admin-id-cards-index') }}" class="btn btn-outline-secondary">Back</a>
    </div>
    <div class="card rounded-4"><div class="card-body">
        @if($submissions->isEmpty())
            <div class="alert alert-info mb-0">There are no ID Card submissions to download.</div>
        @else
            <p id="zipStatus" class="mb-3">Ready to package {{ $submissions->count() }} submission(s).</p>
            <div class="progress mb-3" style="height:10px"><div id="zipProgress" class="progress-bar" style="width:0%"></div></div>
            <button id="downloadZipButton" class="btn btn-primary" type="button" onclick="downloadAllCards()">Download ZIP</button>
        @endif
    </div></div>
</div>
<div class="zip-card-render-area" aria-hidden="true">
@foreach($submissions as $submission)
    <div data-card-pair data-employee-id="{{ $submission->emp_id }}" data-front-id="zip{{ $submission->id }}Front" data-back-id="zip{{ $submission->id }}Back">
        @include('admin.id_cards.partials.card_faces', ['idPrefix' => 'zip'.$submission->id, 'submission' => $submission])
    </div>
@endforeach
</div>
<script>
function canvasBlob(canvas){return new Promise((resolve,reject)=>canvas.toBlob(blob=>blob?resolve(blob):reject(new Error('PNG creation failed.')),'image/png'))}
async function downloadAllCards(){
    const button=document.getElementById('downloadZipButton'),status=document.getElementById('zipStatus'),progress=document.getElementById('zipProgress');
    if(typeof html2canvas==='undefined'||typeof JSZip==='undefined'){status.textContent='Download libraries could not initialize. Refresh the page and try again.';return}
    button.disabled=true;
    try{
        const pairs=[...document.querySelectorAll('[data-card-pair]')],zip=new JSZip(),total=pairs.length*2;let complete=0;
        for(const pair of pairs){
            const employeeId=pair.dataset.employeeId.replace(/[^A-Za-z0-9_-]/g,'_');
            for(const [side,id] of [['Front',pair.dataset.frontId],['Back',pair.dataset.backId]]){
                status.textContent=`Creating ${employeeId}-${side}.png (${complete+1}/${total})`;
                const node=document.getElementById(id);
                for(const image of node.querySelectorAll('img'))if(!image.complete)await image.decode();
                const canvas=await html2canvas(node,{scale:4,useCORS:true,backgroundColor:'#ffffff',scrollX:0,scrollY:0});
                zip.file(`${employeeId}-${side}.png`,await canvasBlob(canvas));
                complete++;progress.style.width=`${Math.round(complete/total*100)}%`;
            }
        }
        status.textContent='Compressing ZIP file…';
        const archive=await zip.generateAsync({type:'blob',compression:'DEFLATE',compressionOptions:{level:6}});
        const link=document.createElement('a');link.href=URL.createObjectURL(archive);link.download='All-ID-Cards.zip';link.click();setTimeout(()=>URL.revokeObjectURL(link.href),1000);
        status.textContent=`Downloaded ${total} ID Card images.`;
    }catch(error){status.textContent=`Unable to create ZIP: ${error.message}`}
    finally{button.disabled=false}
}
</script>
@endsection
