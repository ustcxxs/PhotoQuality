require 'torch'
require 'nn'
require 'image'
require 'optim'
require 'lfs'
require 'io'
require 'loadcaffe'

--------------------------------------------------------------------------------

local cmd = torch.CmdLine()

-- Basic options
cmd:option('-train_dir', 'train/')
cmd:option('-test_dir', 'test/')
cmd:option('-test_template', 'test_template.csv')
cmd:option('-train_labels', 'train_labels.csv')
cmd:option('-content_size', 224, 'Size for content')
cmd:option('-style_size', 400, 'Size for style')
cmd:option('-gpu', 0, 'Zero-indexed ID of the GPU to use; for CPU mode set -gpu = -1')
cmd:option('-input_file', '')

-- Output options
cmd:option('-output_file', 'network.data')
cmd:option('-output_labels', 'test_results.csv')

-- Other options
cmd:option('-step_size', 1e-10)
cmd:option('-style_scale', 1.0)
cmd:option('-dropout', 0.5)
cmd:option('-num_strides', 1)
cmd:option('-save_iter', 2000)
cmd:option('-start_iter', 1)
cmd:option('-max_num_images', 45000)
cmd:option('-normalize_features', 'false')
cmd:option('-pooling', 'max', 'max|avg')
cmd:option('-proto_file', 'models/VGG_ILSVRC_19_layers_deploy.prototxt')
cmd:option('-model_file', 'models/VGG_ILSVRC_19_layers.caffemodel')
cmd:option('-backend', 'nn', 'nn|cudnn|clnn')
cmd:option('-seed', -1)

cmd:option('-content_layer', 'pool5', 'layer to learn from')
cmd:option('-style_layers', 'relu1_1,relu2_1,relu3_1,relu4_1', 'layers for style')


function nn.SpatialConvolutionMM:accGradParameters()
   -- nop.  not needed by our net
end

local function main(params)
   if params.gpu >= 0 then
      if params.backend ~= 'clnn' then
	 require 'cutorch'
	 require 'cunn'
	 cutorch.setDevice(params.gpu + 1)
      else
	 require 'clnn'
	 require 'cltorch'
	 cltorch.setDevice(params.gpu + 1)
      end
   else
      params.backend = 'nn'
   end

   if params.backend == 'cudnn' then
      require 'cudnn'
      if params.cudnn_autotune then
	 cudnn.benchmark = true
      end
      -- cudnn.SpatialConvolution.accGradParameters = nn.SpatialConvolutionMM.accGradParameters -- ie: nop
   end
   
   if params.seed >= 0 then
      torch.manualSeed(params.seed)
   end

   print('loadcaffe')
   local loadcaffe_backend = params.backend
   if params.backend == 'clnn' then loadcaffe_backend = 'nn' end
   local cnn = loadcaffe.load(params.proto_file, params.model_file, loadcaffe_backend):float()
   if params.gpu >= 0 then
      if params.backend ~= 'clnn' then
	 cnn:cuda()
      else
	 cnn:cl()
      end
   end


   print('loadlabels')
   -- load labels
   local flabels = assert(io.open(params.train_labels, "r"))
   local images = {}
   local fake_test = {}
   local i0 = 0
   while true do
      local line = flabels:read('*line')
      if line == nil or i0>100000 then
	 break
      end
      i0 = i0+1
      local parts = line:split('\n')[1]:split(';')
      if #parts == 2 and parts[1] ~= 'ID' then
	 parts[1] = params.train_dir..parts[1]..'.jpg'
	 parts[2] = tonumber(parts[2])
	 if #images >= params.max_num_images then
	    table.insert(fake_test, parts)
	 else
	    table.insert(images, parts)
	 end
      end
   end
   print("Training set: ", #images, #fake_test)
   flabels:close()

   print('loadtest')
   -- load test template
   flabels = assert(io.open(params.test_template, "r"))
   local test_images = {}
   i0 = 0
   while true do
      local line = flabels:read('*line')
      if line == nil or i0>100000 then
	 break
      end
      i0 = i0+1
      local parts = line:split('\n')[1]:split(';')
      if #parts == 2 and parts[1] ~= 'ID' then
	 table.insert(test_images, tonumber(parts[1]))
      end
   end
   print("Testing set: ", #test_images)
   flabels:close()

   -- Set up the network, inserting style descriptor modules
   
   local style_layers = params.style_layers:split(",")
   local pnormalize_features = params.normalize_features:split(",")
   local normalize_features = {}
   
   local qualitynet = nil
   local qualitylayers = nil
   local content_net2 = nil
   local style_net2 = nil
   if params.input_file ~= '' then
      print('loading network')
      obj = torch.load(params.input_file)
      qualitylayers = obj.layers
      content_net2 = obj.cnet
      style_net2 = obj.snet
      obj = nil
   end
   
   print('reading caffe')
   local style_descrs = {}
   local content_descr = nil
   local next_style_idx = 1
   local style_net = nn.Sequential()
   local content_net = nn.Sequential()
   local content_tocome = (content_net2==nil)
   if content_tocome then
      content_net2 = nn.Sequential()
   end
   for i = 1, #cnn do
      if content_tocome or next_style_idx <= #style_layers then
	 local layer = cnn:get(i)
	 local name = layer.name
	 local layer_type = torch.type(layer)
	 if next_style_idx <= #style_layers then
	    style_net:add(layer)
	    content_net:add(layer)
	 elseif content_tocome then
	    content_net2:add(layer)
	 end
	 if name == params.content_layer then
	    print("Setting up content layer  ", i, ":", layer.name)
	    local content_descr = nn.View(-1)
	    if params.gpu >= 0 then
	       if params.backend ~= 'clnn' then
		  content_descr:cuda()
	       else
		  content_descr:cl()
	       end
	    end
	    content_net2:add(content_descr)
	    content_tocome = false
	 end
	 if name == style_layers[next_style_idx] then
	    local norm = (pnormalize_features[#pnormalize_features] == 'true')
	    if #pnormalize_features >= next_style_idx then
	       norm = (pnormalize_features[next_style_idx] == 'true')
	    end
	    table.insert(normalize_features, norm)
	    print("Setting up style layer  ", i, ":", layer.name, 'normalize:', norm)
	    local style_module = nn.StyleDescr(params.style_weight, norm):float()
	    if params.gpu >= 0 then
	       if params.backend ~= 'clnn' then
		  style_module:cuda()
	       else
		  style_module:cl()
	       end
	    end
	    style_net:add(style_module)
	    table.insert(style_descrs, style_module)
	    next_style_idx = next_style_idx + 1
	 end
      end
   end

   -- We don't need the base CNN anymore, so clean it up to save memory.
   cnn = nil
   for i=1, #content_net.modules do
      local module = content_net.modules[i]
      if torch.type(module) == 'nn.SpatialConvolutionMM' then
	 -- remove these, not used, but uses gpu memory
	 module.gradWeight = nil
	 module.gradBias = nil
      end
   end
   
   collectgarbage()
   
   local img_size = params.image_size
   local criterion = nn.MSECriterion()
   local output = torch.Tensor(1)
   if params.backend ~= 'clnn' then
      output = output:cuda()
      criterion:cuda()
   else
      output=output:cl()
   end
  
   local errors = {}
   for j=1, params.num_strides do
      print("stride", j)
      if j>1 then
         params.start_iter = 1
      end
      shuffle(images)
      local toterror = 0
      for i=params.start_iter, #images do
	 print('processing image '..i..': '..images[i][1])
	 collectgarbage()
	 local img = image.load(images[i][1], 3)
	 if img then
	    local res = computeFeatures(params, img, style_net, style_descrs, content_net)
 	    -- init (with good input sizes)
	    if qualitynet == nil then
	       print('Setting up network')
	       qualitynet, qualitylayers = buildNet(params, res, qualitylayers, content_net2)
	    end
	    
	    output[1] = images[i][2]
	    -- training
	    local fwd = qualitynet:forward(res)
	    criterion:forward(fwd, output)
	    print('Note:', math.floor(fwd[1]+0.5), 'expected:', output[1], 'error:', math.floor(criterion.output+0.5))
	    
	    toterror = toterror +  criterion.output
	    qualitynet:zeroGradParameters()
	    grad = qualitynet:backward(res, criterion:backward(qualitynet.output, output))
	    qualitynet:updateParameters(params.step_size)
	 end
	 if i % params.save_iter == 0 then
	   print('\n\n Previous scores', errors)
	   print('\n\nTotal error', toterror/params.save_iter, '\n\n\n')
	   table.insert(errors, toterror/params.save_iter)
	   print('saving network')
	   saveNetwork(params.output_file, qualitylayers, content_net2)
	   toterror = 0
	 end
      end
      print('saving network')
      saveNetwork(params.output_file, qualitylayers, content_net2)
   end

    local freeMemory, totalMemory = cutorch.getMemoryUsage(params.gpu+1)
    print('Memory: ', freeMemory/1024/1024, 'MB free of ', totalMemory/1024/1024)

   print('now testing')
   local fout = io.open('local_tests.csv', 'w')
   fout:write('ID,result,expected')
   if qualitynet~= nil then
      qualitynet:evaluate()
   end
   local toterror =0
   for i=1, #fake_test do
      print('processing image '..i..': '..fake_test[i][1])
      collectgarbage()
 --   local freeMemory, totalMemory = cutorch.getMemoryUsage(params.gpu+1)
 --   print('Memory: ', freeMemory/1024/1024, 'MB free of ', totalMemory/1024/1024)
      local nimg = fake_test[i][1]
      local img = image.load(nimg, 3)

      if img then
         local res = computeFeatures(params, img, style_net, style_descrs, content_net)
	 if qualitynet == nil then
	    print('Setting up network')
	    qualitynet, qualitylayers = buildNet(params, res, qualitylayers, content_net2)
	    qualitynet:evaluate()
	 end
	 local fwd = qualitynet:forward(res)
	 output[1] = fake_test[i][2]
         criterion:forward(fwd, output)
	 print('Note:', math.floor(fwd[1]+0.5), 'expected:', output[1], 'error:', math.floor(criterion.output+0.5))
	 toterror = toterror + criterion.output
	 fout:write('\n'..nimg..','..math.min(100, math.max(0, math.floor(fwd[1]+0.5)))..','..output[1]) 
      end
   end
   fout:close()
   print('\n\n\nExpected score:', toterror/(#fake_test), '\n\n\n')
   
   fout = io.open(params.output_labels, 'w')
   fout:write('ID;aesthetic_score')
   for i=1, #test_images do
      print('processing image '..i..': '..test_images[i])
      collectgarbage()
  --  local freeMemory, totalMemory = cutorch.getMemoryUsage(params.gpu+1)
  --  print('Memory: ', freeMemory/1024/1024, 'MB free of ', totalMemory/1024/1024)
      local nimg = test_images[i]
      local fname = string.format('%s%07d.jpg', params.test_dir, nimg)
      local img = image.load(fname, 3)

      if img then
         local res = computeFeatures(params, img, style_net, style_descrs, content_net)

	 local fwd = qualitynet:forward(res)
	 print(nimg, fwd[1])
	 fout:write('\r'..nimg..';'..math.min(100, math.max(0, math.floor(fwd[1]+0.5)))) 
      end
   end
   fout:close()
end

function shuffle(t)
   for i = #t, 2, -1 do
      local j = math.random(i)
      t[i], t[j] = t[j], t[i]
   end
end

function buildNet(params, res, layers, content_net2)
   local qualitynet = nn.Sequential()
   -- Transform Tables -> Tensor
   local j = nn.ParallelTable()
   local nEl = 0
   for i = 1, #(res[1]) do
      j:add(nn.View(-1))
      nEl = nEl + res[1][i]:nElement()
   end
   -- Content
   local res2b = content_net2:forward(res[2])
   if layers == nil then
       layers = {}
       table.insert(layers, nn.Linear(nEl, 512))
       table.insert(layers, nn.Linear(res2b:nElement(), 512))
       table.insert(layers, nn.Linear(1024, 1024))
       table.insert(layers, nn.Linear(1024, 512))
       table.insert(layers, nn.Linear(512, 1))
       print(nEl, res2b:nElement())
   end
   local m = nn.ParallelTable()
   m:add(j)
   m:add(content_net2)
   local k = nn.Sequential() -- transforms and learn on style
   k:add(nn.JoinTable(1))
   k:add(layers[1])
   local l = nn.ParallelTable()
   l:add(k)
   l:add(layers[2])
   qualitynet:add(m)
   qualitynet:add(l)
   qualitynet:add(nn.JoinTable(1))
   -- Quality Network
   qualitynet:add(nn.ReLU())
   qualitynet:add(nn.Dropout(params.dropout))
   qualitynet:add(layers[3])
   qualitynet:add(nn.ReLU())
   qualitynet:add(nn.Dropout(params.dropout))
   qualitynet:add(layers[4])
   qualitynet:add(nn.ReLU())
   qualitynet:add(nn.Dropout(params.dropout))
   qualitynet:add(layers[5])
--   qualitynet:add(nn.Dropout2(params.dropout))
--   qualitynet:add(nn.Max(1))
   if params.gpu >= 0 then
      if params.backend ~= 'clnn' then
          qualitynet:cuda()
      else
          qualitynet:cl()
      end
   end
   return qualitynet, layers
end

function saveNetwork(name, layers, net)
--   for i=1, #layers do
--      layers[i].output = nil
--      layers[i].gradInput = nil
--   end
   torch.save(name, {layers=layers, onet=net})
end

function computeFeatures(params, imag, style_net, style_descrs, content_net)
   -- style features
   local img = image.scale(imag, params.style_size, 'bilinear')
   local img_caffe = preprocess(img):float()
   if params.gpu >= 0 then
      if params.backend ~= 'clnn' then
	img_caffe = img_caffe:cuda()
      else
	img_caffe = img_caffe:cl()
      end
   end
--   local freeMemory, totalMemory = cutorch.getMemoryUsage(params.gpu+1)
--   print('Memory: ', freeMemory/1024/1024, 'MB free of ', totalMemory/1024/1024)
   style_net:forward(img_caffe)
   local res1 = {}
   for j, mod in ipairs(style_descrs) do
      table.insert(res1, mod.G)
   end
   -- content features
   img = image.scale(imag, params.content_size, params.content_size, 'bilinear')
   img_caffe = preprocess(img):float()
   if params.gpu >= 0 then
      if params.backend ~= 'clnn' then
	img_caffe = img_caffe:cuda()
      else
	img_caffe = img_caffe:cl()
      end
   end
   local res2 = content_net:forward(img_caffe)
   
   return {res1, res2}
end


-- Preprocess an image before passing it to a Caffe model.
-- We need to rescale from [0, 1] to [0, 255], convert from RGB to BGR,
-- and subtract the mean pixel.
function preprocess(img)
   local mean_pixel = torch.DoubleTensor({103.939, 116.779, 123.68})
   local perm = torch.LongTensor{3, 2, 1}
   img = img:index(1, perm):mul(256.0)
   mean_pixel = mean_pixel:view(3, 1, 1):expandAs(img)
   img:add(-1, mean_pixel)
   return img
end


-- Returns a network that computes the CxC Gram matrix from inputs
-- of size C x H x W
function GramMatrix(normalize)
  local net = nn.Sequential()
  net:add(nn.View(-1):setNumInputDims(2))
  if normalize then
    net:add(nn.Normalize(2))
  end
  local concat = nn.ConcatTable()
  concat:add(nn.Identity())
  concat:add(nn.Identity())
  net:add(concat)
  net:add(nn.MM(false, true))
  return net
end


-- Define an nn Module to compute style description (Gram Matrix) in-place
local StyleDescr, parent = torch.class('nn.StyleDescr', 'nn.Module')

function StyleDescr:__init(strength, normalize)
   parent.__init(self)
   self.strength = strength
   self.normalize = normalize or false
   
   self.gram = GramMatrix(self.normalize)
   self.G = nil
end

function StyleDescr:updateOutput(input)
   self.G = torch.triu(self.gram:forward(input))
   if not self.normalize then
     self.G:div(input:nElement())
   end
   self.output = input
   return self.output
end

local Dropout2, Parent = torch.class('nn.Dropout2', 'nn.Dropout')

function Dropout2:__init(p,v1,inplace)
   Parent.__init(self,p,v1,inplace)
end

function Dropout2:updateOutput(input)
   if self.inplace then
      self.output = input
   else
      self.output:resizeAs(input):copy(input)
   end
   if self.p > 0 then
      if self.train then
         self.noise:resizeAs(input)
         self.noise:bernoulli(1-self.p)
         self.output:cmul(self.noise)
      end
   end
   return self.output
end

function Dropout2:updateGradInput(input, gradOutput)
   if self.train then
      if self.inplace then
         self.gradInput = gradOutput
      else
         self.gradInput:resizeAs(gradOutput):copy(gradOutput)
      end
      if self.p > 0 then
         self.gradInput:cmul(self.noise) -- simply mask the gradients with the noise vector
      end
   else
      if self.inplace then
         self.gradInput = gradOutput
      else
         self.gradInput:resizeAs(gradOutput):copy(gradOutput)
      end
   end
   return self.gradInput
end

local params = cmd:parse(arg)
main(params)
