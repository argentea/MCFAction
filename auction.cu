#include "auction.cuh"

#define MAXMY 0x3f3f3f3f

#if DEBUG
__device__ int tans;
#endif

struct AuctionState
{
    int* kpushListPo; ///< length of #nodes * 2
    int* kpushListNa; ///< length of #nodes * 2
    bool* knodesRisePrice; ///< length of #nodes 

    void initialize(Graph const& G)
    {
        printf("initialize state with %d nodes\n", G.getNodesNum());
        kpushListPo = nullptr; 
        kpushListNa = nullptr; 
        knodesRisePrice = nullptr; 

        cudaError_t status = cudaMalloc((void **)&kpushListPo, G.getNodesNum()*3*sizeof(int));
        if (status != cudaSuccess) 
        { 
            printf("cudaMalloc failed for kpushListPo\n"); 
        } 
        status = cudaMalloc((void **)&kpushListNa, G.getNodesNum()*3*sizeof(int));
        if (status != cudaSuccess) 
        { 
            printf("cudaMalloc failed for kpushListNa\n"); 
        } 
        status = cudaMalloc((void **)&knodesRisePrice, G.getNodesNum()*sizeof(bool));
        if (status != cudaSuccess) 
        { 
            printf("cudaMalloc failed for knodesRisePrice\n"); 
        } 
    }

    void destroy()
    {
        cudaFree(kpushListPo);
        cudaFree(kpushListNa); 
        cudaFree(knodesRisePrice);
    }
};

//pushlist is not good
__device__ void pushFlow(
		Graph &G,
        AuctionState& state, 
		const int lnodes,
		const int rnodes,
		const int ledges,
		const int redges,
		const int epsilon,
		const int knumNodes, 
        int& kpoCount, 
        int& knaCount
		){
#if FULLDEBUG
	if(threadIdx.x ==0){
		printf("in pushFlow\n");
	}
	__syncthreads();
#endif
	if(threadIdx.x ==0){
		kpoCount = 0;
		knaCount = 0;
	}
	__syncthreads();

	for(int i = ledges; i < redges; i++){
		int ti,tj,tindex;
		ti = G.edge2source(i);
		tj = G.edge2sink(i);
		if(G.atCost(i) - G.atPrice(ti) + G.atPrice(tj) + epsilon == 0&&G.atGrow(ti) >0){
			tindex = atomicAdd(&kpoCount, 1);
			state.kpushListPo[tindex * 3 + 0] = ti;
			state.kpushListPo[tindex * 3 + 1] = tj;
			state.kpushListPo[tindex * 3 + 2] = i;
			continue;
		}
		if(G.atCost(i) - G.atPrice(ti) + G.atPrice(tj) - epsilon == 0&&G.atGrow(tj) > 0){
			tindex = atomicAdd(&knaCount, 1);
			state.kpushListNa[tindex * 3 + 0] = tj;
			state.kpushListNa[tindex * 3 + 1] = ti;
			state.kpushListNa[tindex * 3 + 2] = i;
			continue;
		}
	}
#if FULLDEBUG
	if(threadIdx.x ==0){
		printf("get pushList\n");
	}
	__syncthreads();
#endif
	__syncthreads();
	int delta,tmpi,tmpj,tmpk;
	if(threadIdx.x == 0){
		for(int i = 0; i < kpoCount; i++){
			tmpi = state.kpushListPo[i * 3 + 0];
			tmpj = state.kpushListPo[i * 3 + 1];
			tmpk = state.kpushListPo[i * 3 + 2];
			delta = min(G.atGrow(tmpi), G.atRb(tmpk) - G.atFlow(tmpk));
			G.setFlow(tmpk, G.atFlow(tmpk) + delta);
			G.atomicSubGrow(tmpi, delta);
			G.atomicAddGrow(tmpj, delta);
		}
		for(int i = 0; i < knaCount; i++){
			tmpi = state.kpushListNa[i * 3 + 0];
			tmpj = state.kpushListNa[i * 3 + 1];
			tmpk = state.kpushListNa[i * 3 + 2];
			delta = min(G.atGrow(tmpi), G.atFlow(tmpk) - G.atLb(tmpk));
			G.setFlow(tmpk, G.atFlow(tmpk) - delta);
			G.atomicSubGrow(tmpi, delta);
			G.atomicAddGrow(tmpj, delta);
		}
	}
	__syncthreads();
#if FULLDEBUG
		if(threadIdx.x == 0){
			printf("out pushFlow\n");
		}
		__syncthreads();
#endif

	return ;
}
__device__ void priceRise(
		Graph &G,
        AuctionState& state, 
		const int lnodes,
		const int rnodes,
		const int ledges,
		const int redges,
		const int epsilon,
		const int knumNodes, 
        int& minRise
		){
#if FULLDEBUG
		if(threadIdx.x == 0){
			printf("in priceRise\n");
		}
		__syncthreads();
#endif

	int ti,tj,tmpa,tmpb;
	for(int i = lnodes; i < rnodes; i++){
		if(G.atGrow(i) > 0){
			state.knodesRisePrice[i] = true;
		}else {
			state.knodesRisePrice[i] = false;
		}
	}
	__syncthreads();
	for(int i = ledges; i < redges; i++){
		ti = G.edge2source(i);
		tj = G.edge2sink(i);
		if(state.knodesRisePrice[ti] != state.knodesRisePrice[tj]){
			if(G.atFlow(i) < G.atRb(i) && state.knodesRisePrice[ti]){
				tmpb = G.atPrice(tj) + G.atCost(i) + epsilon - G.atPrice(ti);
				if(tmpb >= 0){
					atomicMin(&minRise, tmpb);
				}
			}
			if(G.atFlow(i) > G.atLb(i) && state.knodesRisePrice[tj]){
				tmpa = G.atPrice(ti) - G.atCost(i) + epsilon - G.atPrice(tj);
				if(tmpa >= 0){
					atomicMin(&minRise, tmpa);
				}
			}
		}
	}
#if FULLDEBUG
		if(threadIdx.x == 0){
			printf("out priceRise\n");
		}
		__syncthreads();
#endif
	__syncthreads();

}
__global__ void __launch_bounds__(1024)
auction_algorithm_kernel(
		Graph G, 
        AuctionState state 
){
	__shared__ int kepsilon;
	__shared__ int totalIteratorNum;
	__shared__ int iteratorNum;
	__shared__ int scalingFactor;
	__shared__ int costScale;
	__shared__ int gdelta;
	__shared__ int knumNodes;
	__shared__ int knumEdges;
	__shared__ int edgesDivThread;
	__shared__ int nodesDivThread;
    __shared__ int kflag; 
    __shared__ int minRise;
    __shared__ int kpoCount;
    __shared__ int knaCount;

	const int threadId = threadIdx.x;
    if (threadId == 0) {
        kepsilon = 1; 
        totalIteratorNum = 0; 
        iteratorNum = 0; 
        scalingFactor = 2; 
        costScale = 9; 
        gdelta = 0; 
        knumNodes = G.getNodesNum();
        knumEdges = G.getEdgesNum();
        edgesDivThread = max(knumEdges / blockDim.x, 1);
        nodesDivThread = max(knumNodes / blockDim.x, 1);

		printf("in kernel\n");
    }
    __syncthreads();

	//[edgesl,edgesr) is the range of edges that the thread produre
	int ledges = threadId * edgesDivThread;
	int redges = min(ledges + edgesDivThread, knumEdges);

	int lnodes = threadId * nodesDivThread;
	int rnodes = min(lnodes + nodesDivThread, knumNodes);

	int kti;
	int ktj;

	while(costScale >= 0){
#if DEBUG
		if(threadId == 0){
			printf("cost scale: %d\n",costScale);
		}
#endif
		for(int i = lnodes; i < rnodes; i++){
			G.setGrow(i , G.atGrowRaw(i));
		}

		int ktmp = 1<<costScale;

		for(int i = ledges; i < redges; i++){
			G.setFlow(i, 0);
			if(G.atCostRaw(i) <= G.getMaxCost()){
				G.setCost(i, G.atCostRaw(i)/ktmp);
			}
		}
		for(int i = lnodes; i < rnodes; i++){
			G.setPrice(i, G.atPrice(i)*(1 << gdelta));
		}
		__syncthreads();
		for(int i = ledges; i < redges; i++){
			kti = G.edge2source(i);
			ktj = G.edge2sink(i);
			if(G.atCost(i) - G.atPrice(kti) + G.atPrice(ktj) + kepsilon <= 0){
				G.atomicSubGrow(kti, G.atRb(i));
				G.atomicAddGrow(ktj, G.atRb(i));
				G.setFlow(i, G.atRb(i));
			}
		}
		iteratorNum = 0;
		if(threadId == 0)
		{
			kflag = true;
		}
		__syncthreads();

		for(int i = lnodes; i < rnodes; i++){
			if(G.atGrow(i) != 0){
				atomicAnd(&kflag, 0);
			}
		}
		__syncthreads();

		while(!kflag){
#if FULLDEBUG
			if(threadId == 0){
				printf("iteration : %d\n", iteratorNum);
			}
			__syncthreads();
#endif
            pushFlow(
                    G,
                    state, 
                    lnodes,
                    rnodes,
                    ledges,
                    redges,
                    kepsilon,
                    knumNodes, 
                    kpoCount, 
                    knaCount
                    );
			if(threadId == 0){
				minRise = MAXMY;
			}
			__syncthreads();
            priceRise(
                    G,
                    state, 
                    lnodes,
                    rnodes,
                    ledges,
                    redges,
                    kepsilon,
                    knumNodes, 
                    minRise
                    );
			__syncthreads();
#if FULLDEBUG
			if(threadId == 0){
				printf("minRise: %d\n", minRise);
			}
			__syncthreads();
#endif
			if(threadId == 0){
				if(minRise == MAXMY){
					minRise = 0;
				}
			}

			__syncthreads();
			for(int i = lnodes; i < rnodes; i++){
				if(state.knodesRisePrice[i]){
					G.setPrice(i, G.atPrice(i) + minRise);
				}
			}
			__syncthreads();
			if(threadId == 0)
			{
                iteratorNum++;
                totalIteratorNum++;
				kflag = true;
			}
			for(int i = lnodes; i < rnodes; i++){
				if(G.atGrow(i) != 0){
					atomicAnd(&kflag, 0);
				}
			}
			__syncthreads();

		}

#if DEBUG
		if(threadId == 0){
			tans = 0;
		}
		__syncthreads();
		for(int i = ledges; i < redges; i++){
			atomicAdd(&tans, G.atFlow(i)*G.atCostRaw(i));
		}
		if(threadId == 0){
			printf("inner loop out\n");
			printf("temporary ans: %d\n",tans);
			printf("cost scale: %d\n", costScale);
			printf("iteratorNum: %d\n", iteratorNum);
		}
		__syncthreads();
#endif
		if(costScale ==0){
			break;
		}
        if (threadId == 0) {
            gdelta = costScale - max(0, costScale - scalingFactor);
            costScale = max(0, costScale - scalingFactor);
        }
        __syncthreads();
	}


	if(threadId == 0)
	{
		printf("totalIteratorNum: %d\n", totalIteratorNum);
		printf("kenerl end\n");
	}
}

hr_clock_rep timer_start, timer_mem, timer_stop;
void run_auction(
		Graph auctionGraph,
		int threadNum,
		int* hflow){
	std::cout << "start run_auction\n";

	cudaProfilerStart();
	std::cout << "start kernel\n";
    AuctionState state; 
    state.initialize(auctionGraph);
	auction_algorithm_kernel<<<1,threadNum>>>
		(
		auctionGraph, 
        state
		);
    state.destroy();
	cudaProfilerStop();
	cudaDeviceSynchronize();
	timer_stop = get_globaltime();
}

int main(int argc, char *argv[]){
	int threadNum = 1024;
//	initmy(&hC,hedges,hcost,hg,hlb,hrb	);
	timer_start = get_globaltime();
	Graph auctionGraph = Graph(Graph::edgeList, argv[1]);
	timer_mem = get_globaltime();

//	Graph auctionGraph = Graph(Graph::matrix,numNodes, numEdges, hC, hedges, hcost, hlb, hrb, hg);

    std::vector<int> hflow (auctionGraph.getNodesNum() * auctionGraph.getNodesNum(), 0);
	run_auction(
		auctionGraph,
		threadNum,
		hflow.data()
	);

	std::cerr << "run_acution takes "<< (timer_stop - timer_start)*get_timer_period() << "ms totally.\n";
	std::cerr << "memory copy takes "<< (timer_mem - timer_start)*get_timer_period() << "ms totally.\n";
	std::cerr << "kernel takes "<< (timer_stop - timer_mem)*get_timer_period() << "ms totally.\n";
	return 0;
}
